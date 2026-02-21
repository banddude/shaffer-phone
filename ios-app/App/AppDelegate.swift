import UIKit
import UserNotifications
import Contacts
import AVFoundation
import Photos

extension Notification.Name {
    static let openSMSConversation = Notification.Name("openSMSConversation")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var didKickoffPermissionPreflight = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        clearBadge(application)
        UNUserNotificationCenter.current().delegate = self
        kickoffPermissionPreflightIfNeeded(application)
        TwilioVoiceManager.shared.start()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        clearBadge(application)
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrationService.registerAPNSToken(deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLog.error("APNs registration failed: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if isTwilioVoiceNotification(userInfo) {
            TwilioVoiceManager.shared.handleIncomingCallNotificationPayload(userInfo)
            completionHandler(.newData)
            return
        }
        if let number = userInfo["sms_number"] as? String {
            NotificationCenter.default.post(name: .openSMSConversation, object: nil, userInfo: ["number": number])
            completionHandler(.newData)
            return
        }
        completionHandler(.noData)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if isTwilioVoiceNotification(userInfo) {
            TwilioVoiceManager.shared.handleIncomingCallNotificationPayload(userInfo)
            completionHandler()
            return
        }
        if let number = userInfo["sms_number"] as? String {
            NotificationCenter.default.post(name: .openSMSConversation, object: nil, userInfo: ["number": number])
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if isTwilioVoiceNotification(notification.request.content.userInfo) {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound])
    }

    private func isTwilioVoiceNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        if let messageType = userInfo["twi_message_type"] as? String,
           messageType.lowercased().contains("twilio.voice") {
            return true
        }
        if let messageType = userInfo["message_type"] as? String,
           messageType.lowercased().contains("twilio.voice") {
            return true
        }
        return false
    }

    private func clearBadge(_ application: UIApplication) {
        application.applicationIconBadgeNumber = 0
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private func kickoffPermissionPreflightIfNeeded(_ application: UIApplication) {
        guard !didKickoffPermissionPreflight else {
            return
        }
        didKickoffPermissionPreflight = true

        Task { @MainActor in
            await requestNotificationPermissionIfNeeded(application)
            await requestContactsPermissionIfNeeded()
            await requestMicrophonePermissionIfNeeded()
            await requestPhotoLibraryPermissionIfNeeded()
        }
    }

    @MainActor
    private func requestNotificationPermissionIfNeeded(_ application: UIApplication) async {
        let settings = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning: $0) }
        }

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            application.registerForRemoteNotifications()
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        AppLog.error("Notification authorization failed: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: granted)
                }
            }
            if granted {
                application.registerForRemoteNotifications()
            }
        default:
            break
        }
    }

    @MainActor
    private func requestContactsPermissionIfNeeded() async {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else {
            return
        }
        _ = await withCheckedContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, error in
                if let error {
                    AppLog.error("Contacts authorization failed: \(error.localizedDescription)")
                } else {
                    AppLog.info("Contacts authorization granted: \(granted)")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    @MainActor
    private func requestMicrophonePermissionIfNeeded() async {
        _ = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                AppLog.info("Microphone authorization granted: \(granted)")
                continuation.resume(returning: granted)
            }
        }
    }

    @MainActor
    private func requestPhotoLibraryPermissionIfNeeded() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else {
            return
        }
        _ = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                AppLog.info("Photo authorization status: \(newStatus.rawValue)")
                continuation.resume(returning: newStatus)
            }
        }
    }
}
