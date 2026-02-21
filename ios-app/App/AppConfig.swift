import Foundation
import Security

enum AppConfig {
    private enum KeychainHelper {
        private static let service = "com.shaffer-phone.api"

        static func save(key: String, value: String) {
            let data = Data(value.utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }

        static func load(key: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        static func delete(key: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    static var apiBaseURL: String {
        get { UserDefaults.standard.string(forKey: "api_base_url") ?? "https://YOUR_WORKER.workers.dev" }
        set { UserDefaults.standard.set(newValue, forKey: "api_base_url") }
    }

    static var apiToken: String {
        get {
            if let keychainValue = KeychainHelper.load(key: "api_token") {
                return keychainValue
            }
            // Migrate from UserDefaults if present
            if let legacyValue = UserDefaults.standard.string(forKey: "api_token"),
               legacyValue != "REPLACE_WITH_API_TOKEN" {
                KeychainHelper.save(key: "api_token", value: legacyValue)
                UserDefaults.standard.removeObject(forKey: "api_token")
                return legacyValue
            }
            return "REPLACE_WITH_API_TOKEN"
        }
        set {
            KeychainHelper.save(key: "api_token", value: newValue)
            UserDefaults.standard.removeObject(forKey: "api_token")
        }
    }

    static var voiceIdentity: String {
        get { UserDefaults.standard.string(forKey: "voice_identity") ?? "office-line" }
        set { UserDefaults.standard.set(newValue, forKey: "voice_identity") }
    }

    static var setupGuideURL: String {
        get { UserDefaults.standard.string(forKey: "setup_guide_url") ?? "https://github.com/REPLACE_WITH_YOUR_ORG/shaffer-phone/tree/main/worker" }
        set { UserDefaults.standard.set(newValue, forKey: "setup_guide_url") }
    }

    static var pollingInterval: TimeInterval { 5.0 }
    static var enableLocalPollingNotifications: Bool {
        get { UserDefaults.standard.object(forKey: "enable_local_polling_notifications") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "enable_local_polling_notifications") }
    }

    static func apiURL(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(string: apiBaseURL + path)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        return components?.url
    }

    static func voiceTokenURL(ttl: Int = 3600) -> URL? {
        var components = URLComponents(string: apiBaseURL + "/voice-token")
        components?.queryItems = [
            URLQueryItem(name: "identity", value: voiceIdentity),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "ttl", value: String(ttl))
        ]
        return components?.url
    }

    static func authorizedRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func registerDeviceURL() -> URL? {
        apiURL("/register-device")
    }

    static func unregisterDeviceURL() -> URL? {
        apiURL("/unregister-device")
    }

    static var appVersionString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(shortVersion) (\(build))"
    }

    static func normalizeDialDestination(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            return nil
        }

        if let colon = candidate.firstIndex(of: ":"), !candidate.hasPrefix("+") {
            let scheme = candidate[..<colon]
            if !scheme.isEmpty, scheme.allSatisfy(\.isLetter) {
                candidate = String(candidate[candidate.index(after: colon)...])
            }
        }

        if let at = candidate.firstIndex(of: "@") {
            candidate = String(candidate[..<at])
        }

        if let semicolon = candidate.firstIndex(of: ";") {
            candidate = String(candidate[..<semicolon])
        }

        let digits = candidate.filter(\.isNumber)
        if digits.count == 10 {
            return "+1" + digits
        }
        if digits.count == 11, digits.first == "1" {
            return "+" + digits
        }
        if candidate.hasPrefix("+"), digits.count >= 10 {
            return "+" + digits
        }
        return nil
    }
}
