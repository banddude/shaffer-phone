import Foundation

enum AppLog {
    static func info(_ message: String) {
        print("[TwilioOffice][INFO] \(message)")
    }

    static func warn(_ message: String) {
        print("[TwilioOffice][WARN] \(message)")
    }

    static func error(_ message: String) {
        print("[TwilioOffice][ERROR] \(message)")
    }
}
