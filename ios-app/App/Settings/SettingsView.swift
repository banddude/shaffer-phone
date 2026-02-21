import SwiftUI
import UIKit
import UserNotifications
import Contacts
import AVFoundation
import Photos

struct SettingsView: View {
    @StateObject private var voiceManager = TwilioVoiceManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var apiBaseURL: String = AppConfig.apiBaseURL
    @State private var apiToken: String = AppConfig.apiToken
    @State private var voiceIdentity: String = AppConfig.voiceIdentity
    @State private var setupGuideURL: String = AppConfig.setupGuideURL
    @State private var setupLink: String = ""
    @State private var enableLocalPollingNotifications: Bool = AppConfig.enableLocalPollingNotifications
    @State private var statusText: String = ""
    @State private var isTestingSetup: Bool = false
    @State private var showAdvanced: Bool = false
    @State private var setupTestResult: SetupTestResult?
    @State private var notificationPermission: PermissionState = .unknown
    @State private var contactsPermission: PermissionState = .unknown
    @State private var microphonePermission: PermissionState = .unknown
    @State private var photosPermission: PermissionState = .unknown

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick Setup") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Use this app with either:")
                        Text("1. A setup link from your admin, quickest")
                        Text("2. Your own Twilio plus Cloudflare backend")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    TextField("Setup Link (optional)", text: $setupLink)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    Button("Import Setup Link") {
                        importSetupLink()
                    }

                    TextField("Server URL", text: $apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    SecureField("Server Key", text: $apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("This Phone Name", text: $voiceIdentity)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Save") {
                        saveSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task {
                            await saveAndTestSetup()
                        }
                    } label: {
                        HStack {
                            Text(isTestingSetup ? "Testing Setup..." : "Save and Test Setup")
                            if isTestingSetup {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTestingSetup)

                    if let setupTestResult {
                        statusRow(
                            title: setupTestResult.summary,
                            color: setupTestResult.success ? .green : .red
                        )
                        if !setupTestResult.details.isEmpty {
                            Text(setupTestResult.details)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Twilio") {
                            openExternal("https://console.twilio.com/")
                        }
                        .buttonStyle(.bordered)

                        Button("Cloudflare") {
                            openExternal("https://dash.cloudflare.com/")
                        }
                        .buttonStyle(.bordered)

                        Button("Setup Docs") {
                            openExternal(setupGuideURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Permissions") {
                    permissionRow(title: "Notifications", state: notificationPermission)
                    permissionRow(title: "Contacts", state: contactsPermission)
                    permissionRow(title: "Microphone", state: microphonePermission)
                    permissionRow(title: "Photos", state: photosPermission)

                    Button("Check Permissions Again") {
                        Task {
                            await refreshPermissionStatus()
                        }
                    }

                    Button("Request Missing Permissions") {
                        Task {
                            await requestMissingPermissions()
                            await refreshPermissionStatus()
                        }
                    }

                    Button("Open iOS Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else {
                            return
                        }
                        UIApplication.shared.open(url)
                    }
                }

                Section("Voice Status") {
                    statusRow(
                        title: voiceManager.sdkAvailable ? "Twilio SDK ready" : "Twilio SDK unavailable",
                        color: voiceManager.sdkAvailable ? .green : .red
                    )
                    statusRow(
                        title: voiceManager.isVoicePushConfigured ? "Twilio VoIP push configured" : "Worker APNs call notifications active",
                        color: voiceManager.isVoicePushConfigured ? .green : .orange
                    )
                }

                Section("Advanced") {
                    DisclosureGroup("Show Advanced Options", isExpanded: $showAdvanced) {
                        TextField("Setup Docs URL", text: $setupGuideURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()

                        Toggle("Backup text alerts if push fails", isOn: $enableLocalPollingNotifications)
                        Text("If enabled, the app checks for new messages every few seconds and can show local alerts as a fallback.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Re-register push token") {
                            UIApplication.shared.registerForRemoteNotifications()
                            statusText = "Requested push token registration"
                        }
                    }
                }

                if !statusText.isEmpty {
                    Section {
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    Text("Version \(AppConfig.appVersionString)")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task {
                await refreshPermissionStatus()
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    Task {
                        await refreshPermissionStatus()
                    }
                }
            }
        }
    }

    private func statusRow(title: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
        }
    }

    private func permissionRow(title: String, state: PermissionState) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.color)
                .frame(width: 10, height: 10)
            Text(title)
            Spacer()
            Text(state.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func saveSettings() {
        AppConfig.apiBaseURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        AppConfig.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        AppConfig.voiceIdentity = voiceIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        AppConfig.setupGuideURL = setupGuideURL.trimmingCharacters(in: .whitespacesAndNewlines)
        AppConfig.enableLocalPollingNotifications = enableLocalPollingNotifications
        statusText = "Saved"
    }

    private func importSetupLink() {
        let trimmed = setupLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusText = "Paste a setup link first"
            return
        }
        guard let components = URLComponents(string: trimmed) else {
            statusText = "Invalid setup link"
            return
        }

        let items = components.queryItems ?? []
        let valueMap = Dictionary(uniqueKeysWithValues: items.map { ($0.name.lowercased(), $0.value ?? "") })

        let importedBase = valueMap["base"] ?? valueMap["base_url"] ?? valueMap["url"]
        let importedToken = valueMap["token"] ?? valueMap["api_token"] ?? valueMap["key"]
        let importedIdentity = valueMap["identity"] ?? valueMap["voice_identity"] ?? valueMap["device"]

        var importedCount = 0
        if let importedBase, !importedBase.isEmpty {
            apiBaseURL = importedBase
            importedCount += 1
        }
        if let importedToken, !importedToken.isEmpty {
            apiToken = importedToken
            importedCount += 1
        }
        if let importedIdentity, !importedIdentity.isEmpty {
            voiceIdentity = importedIdentity
            importedCount += 1
        }

        if importedCount == 0 {
            statusText = "No usable values in setup link"
            return
        }

        statusText = "Imported setup values"
    }

    private func openExternal(_ rawURL: String) {
        guard let url = URL(string: rawURL) else {
            statusText = "Invalid link"
            return
        }
        UIApplication.shared.open(url)
    }

    private func saveAndTestSetup() async {
        saveSettings()
        isTestingSetup = true
        setupTestResult = nil

        let messagesResult = await testMessagesEndpoint()
        guard messagesResult.success else {
            setupTestResult = messagesResult
            isTestingSetup = false
            return
        }

        let voiceResult = await testVoiceTokenEndpoint()
        setupTestResult = voiceResult
        isTestingSetup = false
    }

    private func testMessagesEndpoint() async -> SetupTestResult {
        guard let url = AppConfig.apiURL("/api/messages") else {
            return SetupTestResult(success: false, summary: "Setup test failed", details: "Invalid API Base URL or token.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return SetupTestResult(success: false, summary: "Setup test failed", details: "No HTTP response from /api/messages.")
            }
            guard (200...299).contains(http.statusCode) else {
                return SetupTestResult(success: false, summary: "Setup test failed", details: "Backend returned status \(http.statusCode) for /api/messages.")
            }
            return SetupTestResult(success: true, summary: "Messages API connected", details: "")
        } catch {
            return SetupTestResult(success: false, summary: "Setup test failed", details: "Could not reach /api/messages, \(error.localizedDescription)")
        }
    }

    private func testVoiceTokenEndpoint() async -> SetupTestResult {
        guard let url = AppConfig.voiceTokenURL(ttl: 300) else {
            return SetupTestResult(success: false, summary: "Setup test failed", details: "Invalid Voice Token URL, check worker URL, token, and identity.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return SetupTestResult(success: false, summary: "Setup test failed", details: "No HTTP response from /voice-token.")
            }
            guard (200...299).contains(http.statusCode) else {
                return SetupTestResult(success: false, summary: "Setup test failed", details: "Backend returned status \(http.statusCode) for /voice-token.")
            }
            guard let decoded = try? JSONDecoder().decode(TwilioVoiceTokenResponse.self, from: data),
                  !decoded.token.isEmpty else {
                return SetupTestResult(success: false, summary: "Setup test failed", details: "Could not decode voice token response.")
            }
            return SetupTestResult(success: true, summary: "Setup test passed", details: "Messages and voice token checks succeeded.")
        } catch {
            return SetupTestResult(success: false, summary: "Setup test failed", details: "Could not reach /voice-token, \(error.localizedDescription)")
        }
    }

    private func requestMissingPermissions() async {
        let notificationSettings = await getNotificationSettings()
        if notificationSettings.authorizationStatus == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }

        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                CNContactStore().requestAccess(for: .contacts) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }

        if AVAudioSession.sharedInstance().recordPermission == .undetermined {
            _ = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func refreshPermissionStatus() async {
        let notificationSettings = await getNotificationSettings()
        notificationPermission = PermissionState(notificationSettings.authorizationStatus)
        contactsPermission = PermissionState(CNContactStore.authorizationStatus(for: .contacts))
        microphonePermission = PermissionState(AVAudioSession.sharedInstance().recordPermission)
        photosPermission = PermissionState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private func getNotificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }
}

private struct SetupTestResult {
    let success: Bool
    let summary: String
    let details: String
}

private enum PermissionState {
    case allowed
    case denied
    case notDetermined
    case unknown

    var color: Color {
        switch self {
        case .allowed: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .unknown: return .gray
        }
    }

    var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked"
        case .unknown: return "Unknown"
        }
    }
}

private extension PermissionState {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            self = .allowed
        case .denied:
            self = .denied
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .unknown
        }
    }

    init(_ status: CNAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            self = .allowed
        case .denied, .restricted:
            self = .denied
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .unknown
        }
    }

    init(_ status: AVAudioSession.RecordPermission) {
        switch status {
        case .granted:
            self = .allowed
        case .denied:
            self = .denied
        case .undetermined:
            self = .notDetermined
        @unknown default:
            self = .unknown
        }
    }

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            self = .allowed
        case .denied, .restricted:
            self = .denied
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .unknown
        }
    }
}
