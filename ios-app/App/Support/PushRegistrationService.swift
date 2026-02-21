import Foundation
import UIKit

enum PushRegistrationService {
    static func registerAPNSToken(_ tokenData: Data) {
        guard let url = AppConfig.registerDeviceURL() else {
            AppLog.error("Push register URL is invalid")
            return
        }

        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-unknown"
        #if DEBUG
        let apnsEnvironment = "development"
        #else
        let apnsEnvironment = "production"
        #endif
        let payload: [String: Any] = [
            "token": token,
            "deviceId": deviceId,
            "bundleId": Bundle.main.bundleIdentifier ?? "com.example.shafferphone",
            "environment": apnsEnvironment,
            "platform": "ios",
            "locale": Locale.current.identifier,
            "appVersion": AppConfig.appVersionString,
            "voiceIdentity": AppConfig.voiceIdentity
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(AppConfig.apiToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    AppLog.error("Push token register failed: \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    AppLog.error("Push token register failed: no HTTP response")
                    return
                }
                if !(200...299).contains(http.statusCode) {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    AppLog.error("Push token register failed with status \(http.statusCode): \(body)")
                    return
                }
                AppLog.info("Push token registration succeeded")
            }.resume()
        } catch {
            AppLog.error("Push token register request encoding failed: \(error.localizedDescription)")
        }
    }

    static func unregisterCurrentDevice() {
        guard let url = AppConfig.unregisterDeviceURL() else {
            return
        }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-unknown"

        let payload: [String: Any] = [
            "deviceId": deviceId
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(AppConfig.apiToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        } catch {
            AppLog.error("Push token unregister request encoding failed: \(error.localizedDescription)")
        }
    }
}
