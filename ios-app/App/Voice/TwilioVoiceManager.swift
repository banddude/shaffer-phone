import Foundation
import CallKit
import PushKit
import AVFoundation

#if canImport(TwilioVoice)
import TwilioVoice
#endif

struct TwilioVoiceTokenResponse: Decodable {
    let token: String
    let identity: String
    let expiresAt: Int
    let pushCredentialSid: String?
}

enum VoiceCallDirection: String, Codable {
    case inbound
    case outbound
}

struct VoiceCallHistoryEntry: Identifiable, Codable {
    let id: UUID
    let remote: String
    let direction: VoiceCallDirection
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    let result: String
}

final class TwilioVoiceManager: NSObject, ObservableObject {
    static let shared = TwilioVoiceManager()

    @Published private(set) var isReady = false
    @Published private(set) var isVoicePushConfigured = false
    @Published private(set) var isInCall = false
    @Published private(set) var isMuted = false
    @Published private(set) var isOnHold = false
    @Published private(set) var isSpeakerOn = false
    @Published private(set) var callStatus = "Idle"
    @Published private(set) var activeRemote = ""
    @Published private(set) var callHistory: [VoiceCallHistoryEntry] = []
    @Published private(set) var lastErrorMessage: String?

    private let tokenRefreshPaddingSeconds: TimeInterval = 120
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?
    private var cachedDeviceToken: Data?
    private var didStart = false

    private var pendingOutgoingDestinations: [UUID: String] = [:]
    private var activeCallUUID: UUID?
    private let provider: CXProvider
    private let callController = CXCallController()
    private let callObserver = CXCallObserver()
    private var voipRegistry: PKPushRegistry?
    private let callHistoryStorageKey = "twilio.voice.call-history.v1"
    private let maxHistoryEntries = 250
    private var finalizedCallUUIDs: Set<UUID> = []

    #if canImport(TwilioVoice)
    private let audioDevice = DefaultAudioDevice()
    private var pendingInvites: [UUID: TwilioVoice.CallInvite] = [:]
    private var activeCalls: [UUID: TwilioVoice.Call] = [:]
    #endif
    private var callMetadataByUUID: [UUID: ActiveCallMetadata] = [:]

    private struct ActiveCallMetadata {
        var direction: VoiceCallDirection
        var remote: String
        var startedAt: Date
        var connectedAt: Date?
    }

    private override init() {
        let config = CXProviderConfiguration(localizedName: "Office Line")
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportsVideo = false
        config.includesCallsInRecents = true
        config.supportedHandleTypes = [.phoneNumber, .generic]

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)

        #if canImport(TwilioVoice)
        TwilioVoiceSDK.audioDevice = audioDevice
        #endif

        loadCallHistory()
    }

    var sdkAvailable: Bool {
        #if canImport(TwilioVoice)
        return true
        #else
        return false
        #endif
    }

    func start() {
        guard !didStart else {
            return
        }
        didStart = true

        callObserver.setDelegate(self, queue: .main)
        syncFromCallObserver(callObserver.calls)

        #if canImport(TwilioVoice)
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
        preflightVoiceSetup()
        setReady(true)
        AppLog.info("Twilio voice manager started")
        #else
        setReady(false)
        publishError("Twilio Voice SDK is not linked")
        #endif
    }

    func startOutgoingCall(rawDestination: String) {
        guard sdkAvailable else {
            publishError("Twilio Voice SDK is not linked")
            return
        }

        guard let destination = AppConfig.normalizeDialDestination(rawDestination) else {
            publishError("Invalid phone number")
            return
        }

        let callUUID = UUID()
        activeCallUUID = callUUID
        pendingOutgoingDestinations[callUUID] = destination
        setCallStatus("Dialing \(destination)")
        setActiveRemote(destination)
        rememberCallMetadata(
            uuid: callUUID,
            direction: .outbound,
            remote: destination
        )

        let handle = CXHandle(type: .phoneNumber, value: destination)
        let startAction = CXStartCallAction(call: callUUID, handle: handle)
        startAction.isVideo = false

        let transaction = CXTransaction(action: startAction)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.pendingOutgoingDestinations.removeValue(forKey: callUUID)
                self?.finalizeCallMetadata(
                    uuid: callUUID,
                    result: "Failed",
                    fallbackRemote: destination,
                    fallbackDirection: .outbound
                )
                self?.publishError("Call start failed: \(error.localizedDescription)")
                return
            }

            let update = CXCallUpdate()
            update.remoteHandle = handle
            update.localizedCallerName = destination
            update.hasVideo = false
            update.supportsDTMF = true
            update.supportsHolding = true
            update.supportsGrouping = false
            update.supportsUngrouping = false
            self?.provider.reportCall(with: callUUID, updated: update)
        }
    }

    func toggleMute() {
        guard let callUUID = activeCallUUID else {
            publishError("No active call")
            return
        }

        let action = CXSetMutedCallAction(call: callUUID, muted: !isMuted)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.publishError("Mute action failed: \(error.localizedDescription)")
            }
        }
    }

    func toggleHold() {
        guard let callUUID = activeCallUUID else {
            publishError("No active call")
            return
        }

        let action = CXSetHeldCallAction(call: callUUID, onHold: !isOnHold)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.publishError("Hold action failed: \(error.localizedDescription)")
            }
        }
    }

    func sendDTMF(_ digits: String) {
        guard let callUUID = activeCallUUID else {
            publishError("No active call")
            return
        }

        let cleaned = digits.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return
        }

        let action = CXPlayDTMFCallAction(call: callUUID, digits: cleaned, type: .singleTone)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.publishError("DTMF failed: \(error.localizedDescription)")
            }
        }
    }

    func toggleSpeaker() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true, options: [])
            try session.overrideOutputAudioPort(isSpeakerOn ? .none : .speaker)
            setSpeakerOn(!isSpeakerOn)
        } catch {
            publishError("Speaker route failed: \(error.localizedDescription)")
        }
    }

    func endActiveCall() {
        guard let callUUID = preferredCallUUIDForEnding() else {
            return
        }

        let action = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.publishError("End call failed: \(error.localizedDescription)")
            }
        }
    }

    func answerIncomingCall() {
        guard let callUUID = preferredIncomingCallUUID() else {
            publishError("No incoming call")
            return
        }

        let action = CXAnswerCallAction(call: callUUID)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.publishError("Answer call failed: \(error.localizedDescription)")
            }
        }
    }

    func declineIncomingCall() {
        guard let callUUID = preferredIncomingCallUUID() ?? preferredCallUUIDForEnding() else {
            return
        }

        let action = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { [weak self] error in
            if let error {
                self?.publishError("Decline call failed: \(error.localizedDescription)")
            }
        }
    }

    func endAllCalls() {
        #if canImport(TwilioVoice)
        for (_, call) in activeCalls {
            call.disconnect()
        }
        activeCalls.removeAll()
        pendingOutgoingDestinations.removeAll()
        pendingInvites.removeAll()
        #endif
        resetCallState()
    }

    func clearCallHistory() {
        DispatchQueue.main.async {
            self.callHistory = []
            UserDefaults.standard.removeObject(forKey: self.callHistoryStorageKey)
        }
    }

    func handleIncomingCallNotificationPayload(_ payload: [AnyHashable: Any]) {
        #if canImport(TwilioVoice)
        TwilioVoiceSDK.handleNotification(payload, delegate: self, delegateQueue: nil)
        #endif
    }

    private func fetchVoiceToken(forceRefresh: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        if !forceRefresh,
           let cachedToken,
           let cachedTokenExpiry,
           cachedTokenExpiry.timeIntervalSinceNow > tokenRefreshPaddingSeconds {
            completion(.success(cachedToken))
            return
        }

        guard let url = AppConfig.voiceTokenURL() else {
            completion(.failure(NSError(domain: "TwilioVoice", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid token URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(AppConfig.apiToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "TwilioVoice", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing HTTP response"])))
                return
            }

            guard (200...299).contains(http.statusCode), let data else {
                completion(.failure(NSError(domain: "TwilioVoice", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Token request failed with status \(http.statusCode)"])))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(TwilioVoiceTokenResponse.self, from: data)
                self?.cachedToken = decoded.token
                self?.cachedTokenExpiry = Date(timeIntervalSince1970: TimeInterval(decoded.expiresAt))
                self?.setVoicePushConfigured(!(decoded.pushCredentialSid ?? "").isEmpty)
                completion(.success(decoded.token))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func preflightVoiceSetup() {
        fetchVoiceToken(forceRefresh: true) { [weak self] result in
            if case let .failure(error) = result {
                self?.publishError("Voice preflight failed: \(error.localizedDescription)")
            }
        }
    }

    private func registerVoIPPushIfNeeded(with deviceToken: Data) {
        #if canImport(TwilioVoice)
        fetchVoiceToken { [weak self] result in
            switch result {
            case .success(let token):
                TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { error in
                    if let error {
                        self?.publishError("Push registration failed: \(error.localizedDescription)")
                    } else {
                        AppLog.info("Push registration succeeded")
                        self?.cachedDeviceToken = deviceToken
                    }
                }
            case .failure(let error):
                self?.publishError("Token fetch failed during push registration: \(error.localizedDescription)")
            }
        }
        #endif
    }

    private func unregisterVoIPPushIfNeeded() {
        #if canImport(TwilioVoice)
        guard let cachedDeviceToken else {
            return
        }

        fetchVoiceToken(forceRefresh: true) { [weak self] result in
            switch result {
            case .success(let token):
                TwilioVoiceSDK.unregister(accessToken: token, deviceToken: cachedDeviceToken) { error in
                    if let error {
                        self?.publishError("Push unregistration failed: \(error.localizedDescription)")
                    } else {
                        AppLog.info("Push unregistration succeeded")
                    }
                }
            case .failure(let error):
                self?.publishError("Token fetch failed during push unregistration: \(error.localizedDescription)")
            }
        }
        #endif
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.lastErrorMessage = message
        }
        AppLog.error(message)
    }

    private func setReady(_ ready: Bool) {
        DispatchQueue.main.async {
            self.isReady = ready
        }
    }

    private func setInCall(_ inCall: Bool) {
        DispatchQueue.main.async {
            self.isInCall = inCall
        }
    }

    private func setMuted(_ muted: Bool) {
        DispatchQueue.main.async {
            self.isMuted = muted
        }
    }

    private func setOnHold(_ onHold: Bool) {
        DispatchQueue.main.async {
            self.isOnHold = onHold
        }
    }

    private func setSpeakerOn(_ speakerOn: Bool) {
        DispatchQueue.main.async {
            self.isSpeakerOn = speakerOn
        }
    }

    private func setCallStatus(_ status: String) {
        DispatchQueue.main.async {
            self.callStatus = status
        }
    }

    private func setVoicePushConfigured(_ configured: Bool) {
        DispatchQueue.main.async {
            self.isVoicePushConfigured = configured
        }
    }

    private func setActiveRemote(_ value: String) {
        DispatchQueue.main.async {
            self.activeRemote = value
        }
    }

    private func preferredCallUUIDForEnding() -> UUID? {
        if let activeCallUUID {
            return activeCallUUID
        }
        return callObserver.calls.first(where: { !$0.hasEnded })?.uuid
    }

    private func preferredIncomingCallUUID() -> UUID? {
        if let incomingUUID = callObserver.calls.first(where: { !$0.hasEnded && !$0.hasConnected && !$0.isOutgoing })?.uuid {
            return incomingUUID
        }
        #if canImport(TwilioVoice)
        return pendingInvites.keys.first
        #else
        return nil
        #endif
    }

    private func rememberCallMetadata(
        uuid: UUID,
        direction: VoiceCallDirection,
        remote: String
    ) {
        finalizedCallUUIDs.remove(uuid)
        callMetadataByUUID[uuid] = ActiveCallMetadata(
            direction: direction,
            remote: sanitizeRemote(remote),
            startedAt: Date(),
            connectedAt: nil
        )
    }

    private func markCallConnected(uuid: UUID) {
        guard var metadata = callMetadataByUUID[uuid] else {
            return
        }
        metadata.connectedAt = metadata.connectedAt ?? Date()
        callMetadataByUUID[uuid] = metadata
    }

    private func finalizeCallMetadata(
        uuid: UUID,
        result: String,
        endedAt: Date = Date(),
        fallbackRemote: String? = nil,
        fallbackDirection: VoiceCallDirection? = nil
    ) {
        if finalizedCallUUIDs.contains(uuid) {
            return
        }
        finalizedCallUUIDs.insert(uuid)
        if finalizedCallUUIDs.count > maxHistoryEntries * 2 {
            finalizedCallUUIDs.removeAll(keepingCapacity: true)
        }

        let metadata = callMetadataByUUID.removeValue(forKey: uuid)
        let direction = metadata?.direction ?? fallbackDirection ?? .outbound
        let remote = sanitizeRemote(metadata?.remote ?? fallbackRemote ?? activeRemote)
        let startedAt = metadata?.startedAt ?? endedAt
        let durationSeconds = max(
            0,
            Int(endedAt.timeIntervalSince(metadata?.connectedAt ?? endedAt))
        )

        addCallHistoryEntry(
            VoiceCallHistoryEntry(
                id: UUID(),
                remote: remote,
                direction: direction,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: durationSeconds,
                result: result
            )
        )
    }

    private func sanitizeRemote(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "client:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Unknown" : cleaned
    }

    private func addCallHistoryEntry(_ entry: VoiceCallHistoryEntry) {
        DispatchQueue.main.async {
            self.callHistory.insert(entry, at: 0)
            if self.callHistory.count > self.maxHistoryEntries {
                self.callHistory.removeLast(self.callHistory.count - self.maxHistoryEntries)
            }
            self.persistCallHistory()
        }
    }

    private func persistCallHistory() {
        guard let encoded = try? JSONEncoder().encode(callHistory) else {
            return
        }
        UserDefaults.standard.set(encoded, forKey: callHistoryStorageKey)
    }

    private func loadCallHistory() {
        guard let encoded = UserDefaults.standard.data(forKey: callHistoryStorageKey),
              let decoded = try? JSONDecoder().decode([VoiceCallHistoryEntry].self, from: encoded)
        else {
            return
        }
        callHistory = decoded
    }

    private func syncFromCallObserver(_ calls: [CXCall]) {
        if let active = calls.first(where: { !$0.hasEnded }) {
            activeCallUUID = active.uuid
            setInCall(true)
            setOnHold(active.isOnHold)

            if active.hasConnected {
                setCallStatus(active.isOnHold ? "On hold" : "Connected")
            } else {
                setCallStatus(active.isOutgoing ? "Connecting" : "Incoming")
            }
            return
        }

        if activeCallsIsEmpty {
            resetCallState()
        }
    }

    private var activeCallsIsEmpty: Bool {
        #if canImport(TwilioVoice)
        return activeCalls.isEmpty && pendingInvites.isEmpty
        #else
        return true
        #endif
    }

    private func resetCallState() {
        DispatchQueue.main.async {
            self.isInCall = false
            self.isMuted = false
            self.isOnHold = false
            self.isSpeakerOn = false
            self.callStatus = "Idle"
            self.activeRemote = ""
        }
        activeCallUUID = nil
    }
}

extension TwilioVoiceManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else {
            return
        }
        registerVoIPPushIfNeeded(with: credentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else {
            return
        }
        unregisterVoIPPushIfNeeded()
        cachedDeviceToken = nil
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        guard type == .voIP else {
            return
        }
        #if canImport(TwilioVoice)
        TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        #endif
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }
        #if canImport(TwilioVoice)
        TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: nil)
        #endif
        completion()
    }
}

extension TwilioVoiceManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        #if canImport(TwilioVoice)
        pendingInvites.removeAll()
        activeCalls.removeAll()
        #endif
        pendingOutgoingDestinations.removeAll()
        callMetadataByUUID.removeAll()
        syncFromCallObserver(callObserver.calls)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let destination = pendingOutgoingDestinations[action.callUUID] else {
            action.fail()
            return
        }

        #if canImport(TwilioVoice)
        activeCallUUID = action.callUUID
        setActiveRemote(destination)
        setCallStatus("Connecting")
        rememberCallMetadata(
            uuid: action.callUUID,
            direction: .outbound,
            remote: destination
        )
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()

        fetchVoiceToken { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                switch result {
                case .success(let token):
                    let options = ConnectOptions(accessToken: token) { builder in
                        builder.params = ["To": destination]
                        builder.uuid = action.callUUID
                    }

                    let call = TwilioVoiceSDK.connect(options: options, delegate: self)
                    self.activeCalls[action.callUUID] = call
                    self.setInCall(true)

                case .failure(let error):
                    self.publishError("Failed to start outgoing call: \(error.localizedDescription)")
                    self.pendingOutgoingDestinations.removeValue(forKey: action.callUUID)
                    self.finalizeCallMetadata(
                        uuid: action.callUUID,
                        result: "Failed",
                        fallbackRemote: destination,
                        fallbackDirection: .outbound
                    )
                    self.provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
                    self.resetCallState()
                }
            }
        }
        #else
        action.fail()
        #endif
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        #if canImport(TwilioVoice)
        guard let invite = pendingInvites[action.callUUID] else {
            action.fail()
            return
        }

        let options = AcceptOptions(callInvite: invite) { builder in
            builder.uuid = invite.uuid
        }

        let call = invite.accept(options: options, delegate: self)
        activeCalls[action.callUUID] = call
        activeCallUUID = action.callUUID
        rememberCallMetadata(
            uuid: action.callUUID,
            direction: .inbound,
            remote: invite.from ?? "Incoming call"
        )
        pendingInvites.removeValue(forKey: action.callUUID)
        setInCall(true)
        setCallStatus("Connecting")
        action.fulfill()
        #else
        action.fail()
        #endif
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        #if canImport(TwilioVoice)
        if let invite = pendingInvites[action.callUUID] {
            invite.reject()
            pendingInvites.removeValue(forKey: action.callUUID)
            finalizeCallMetadata(
                uuid: action.callUUID,
                result: "Declined",
                fallbackRemote: invite.from ?? "Incoming call",
                fallbackDirection: .inbound
            )
            resetCallState()
            action.fulfill()
            return
        }

        if let call = activeCalls[action.callUUID] {
            call.disconnect()
            activeCalls.removeValue(forKey: action.callUUID)
            if activeCalls.isEmpty {
                resetCallState()
            } else {
                setInCall(true)
            }
            action.fulfill()
            return
        }
        #endif

        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        #if canImport(TwilioVoice)
        guard let call = activeCalls[action.callUUID] else {
            action.fail()
            return
        }
        call.isMuted = action.isMuted
        setMuted(action.isMuted)
        action.fulfill()
        #else
        action.fail()
        #endif
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        #if canImport(TwilioVoice)
        guard let call = activeCalls[action.callUUID] else {
            action.fail()
            return
        }
        call.isOnHold = action.isOnHold
        setOnHold(action.isOnHold)
        setCallStatus(action.isOnHold ? "On hold" : "Connected")
        action.fulfill()
        #else
        action.fail()
        #endif
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        #if canImport(TwilioVoice)
        guard let call = activeCalls[action.callUUID] else {
            action.fail()
            return
        }
        call.sendDigits(action.digits)
        action.fulfill()
        #else
        action.fail()
        #endif
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        #if canImport(TwilioVoice)
        audioDevice.isEnabled = true
        #endif
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        #if canImport(TwilioVoice)
        audioDevice.isEnabled = false
        #endif
    }
}

extension TwilioVoiceManager: CXCallObserverDelegate {
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded, !finalizedCallUUIDs.contains(call.uuid) {
            let result: String
            if call.hasConnected {
                result = "Completed"
            } else if call.isOutgoing {
                result = "Failed"
            } else {
                result = "Missed"
            }
            finalizeCallMetadata(
                uuid: call.uuid,
                result: result,
                fallbackDirection: call.isOutgoing ? .outbound : .inbound
            )
        }
        syncFromCallObserver(callObserver.calls)
    }
}

#if canImport(TwilioVoice)
extension TwilioVoiceManager: NotificationDelegate {
    func callInviteReceived(callInvite: TwilioVoice.CallInvite) {
        pendingInvites[callInvite.uuid] = callInvite
        activeCallUUID = callInvite.uuid
        rememberCallMetadata(
            uuid: callInvite.uuid,
            direction: .inbound,
            remote: callInvite.from ?? "Incoming call"
        )

        let from = (callInvite.from ?? "Incoming call")
            .replacingOccurrences(of: "client:", with: "")
        setActiveRemote(from)
        setCallStatus("Incoming")

        let update = CXCallUpdate()
        update.localizedCallerName = from
        update.remoteHandle = CXHandle(type: .generic, value: from)
        update.hasVideo = false

        provider.reportNewIncomingCall(with: callInvite.uuid, update: update) { [weak self] error in
            if let error {
                self?.publishError("Failed to report incoming call: \(error.localizedDescription)")
                self?.pendingInvites.removeValue(forKey: callInvite.uuid)
            }
        }
    }

    func cancelledCallInviteReceived(cancelledCallInvite: TwilioVoice.CancelledCallInvite, error: Error) {
        guard let invite = pendingInvites.values.first(where: { $0.callSid == cancelledCallInvite.callSid }) else {
            return
        }
        pendingInvites.removeValue(forKey: invite.uuid)
        finalizeCallMetadata(
            uuid: invite.uuid,
            result: "Missed",
            fallbackRemote: invite.from ?? "Incoming call",
            fallbackDirection: .inbound
        )
        provider.reportCall(with: invite.uuid, endedAt: Date(), reason: .remoteEnded)
        resetCallState()
    }
}

extension TwilioVoiceManager: TwilioVoice.CallDelegate {
    func callDidStartRinging(call: TwilioVoice.Call) {
        AppLog.info("Outgoing call is ringing")
        setCallStatus("Ringing")
    }

    func callDidConnect(call: TwilioVoice.Call) {
        if let uuid = call.uuid {
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
            markCallConnected(uuid: uuid)
        }
        setInCall(true)
        setCallStatus("Connected")
    }

    func callIsReconnecting(call: TwilioVoice.Call, error: Error) {
        AppLog.warn("Call reconnecting: \(error.localizedDescription)")
    }

    func callDidReconnect(call: TwilioVoice.Call) {
        AppLog.info("Call reconnected")
    }

    func callDidFailToConnect(call: TwilioVoice.Call, error: Error) {
        publishError("Call failed: \(error.localizedDescription)")
        guard let uuid = call.uuid ?? activeCallUUID else {
            resetCallState()
            return
        }
        finalizeCallMetadata(
            uuid: uuid,
            result: "Failed"
        )
        activeCalls.removeValue(forKey: uuid)
        pendingOutgoingDestinations.removeValue(forKey: uuid)
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        resetCallState()
    }

    func callDidDisconnect(call: TwilioVoice.Call, error: Error?) {
        guard let uuid = call.uuid ?? activeCallUUID else {
            resetCallState()
            return
        }
        let wasConnected = callMetadataByUUID[uuid]?.connectedAt != nil
        let direction = callMetadataByUUID[uuid]?.direction
        let result: String
        if error != nil {
            result = "Failed"
        } else if wasConnected {
            result = "Completed"
        } else if direction == .inbound {
            result = "Missed"
        } else {
            result = "Failed"
        }
        finalizeCallMetadata(uuid: uuid, result: result)

        activeCalls.removeValue(forKey: uuid)
        pendingOutgoingDestinations.removeValue(forKey: uuid)

        let reason: CXCallEndedReason = error == nil ? .remoteEnded : .failed
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        if activeCalls.isEmpty {
            resetCallState()
        } else {
            setInCall(true)
        }

        if let error {
            publishError("Call disconnected: \(error.localizedDescription)")
        }
    }
}
#endif
