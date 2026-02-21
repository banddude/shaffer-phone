import Foundation

struct SMSConversation: Identifiable, Codable {
    let number: String
    let lastMessage: String
    let lastTimestamp: String
    let messageCount: Int
    let hasMedia: Bool

    var id: String { number }

    var formattedNumber: String {
        SMSUtils.formatPhoneNumber(number)
    }

    var relativeTime: String {
        SMSUtils.relativeTimeString(from: lastTimestamp)
    }
}

struct SMSMessageItem: Identifiable, Codable {
    let id: String
    let direction: String
    let from: String
    let to: String
    let body: String
    let media: [SMSMedia]
    let timestamp: String

    var isOutgoing: Bool { direction == "outbound" }

    var formattedTime: String {
        SMSUtils.timeString(from: timestamp)
    }
}

struct SMSMedia: Codable {
    let url: String
    let contentType: String

    var id: String {
        "\(url)|\(contentType)"
    }

    var isImage: Bool {
        contentType.hasPrefix("image/")
    }

    var isVideo: Bool {
        contentType.hasPrefix("video/")
    }

    var isAudio: Bool {
        contentType.hasPrefix("audio/")
    }

    var fileExtension: String {
        if let ext = URL(string: url)?.pathExtension, !ext.isEmpty {
            return ext
        }
        let type = contentType.lowercased()
        if type == "image/jpeg" { return "jpg" }
        if type == "image/png" { return "png" }
        if type == "image/gif" { return "gif" }
        if type == "image/webp" { return "webp" }
        if type == "video/quicktime" { return "mov" }
        if type == "video/mp4" { return "mp4" }
        if type == "video/3gpp" { return "3gp" }
        if type == "video/3gpp2" { return "3g2" }
        if isImage { return "jpg" }
        if isVideo { return "mp4" }
        if isAudio { return "m4a" }
        return "bin"
    }
}

struct SMSConversationsResponse: Codable {
    let conversations: [SMSConversation]
}

struct SMSMessagesResponse: Codable {
    let number: String
    let messages: [SMSMessageItem]
}

struct SMSSendResponse: Codable {
    let success: Bool?
    let sid: String?
    let error: String?
}

enum SMSUtils {
    static func formatPhoneNumber(_ number: String) -> String {
        let digits = number.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        if digits.count == 11 && digits.hasPrefix("1") {
            let area = digits[digits.index(digits.startIndex, offsetBy: 1)..<digits.index(digits.startIndex, offsetBy: 4)]
            let prefix = digits[digits.index(digits.startIndex, offsetBy: 4)..<digits.index(digits.startIndex, offsetBy: 7)]
            let line = digits[digits.index(digits.startIndex, offsetBy: 7)..<digits.index(digits.startIndex, offsetBy: 11)]
            return "(\(area)) \(prefix)-\(line)"
        }
        if digits.count == 10 {
            let area = digits[digits.startIndex..<digits.index(digits.startIndex, offsetBy: 3)]
            let prefix = digits[digits.index(digits.startIndex, offsetBy: 3)..<digits.index(digits.startIndex, offsetBy: 6)]
            let line = digits[digits.index(digits.startIndex, offsetBy: 6)..<digits.index(digits.startIndex, offsetBy: 10)]
            return "(\(area)) \(prefix)-\(line)"
        }
        return number
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ isoString: String) -> Date? {
        isoFormatter.date(from: isoString) ?? isoFormatterNoFractional.date(from: isoString)
    }

    static func relativeTimeString(from isoString: String) -> String {
        guard let date = parseDate(isoString) else { return "" }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        if diff < 604800 { return "\(Int(diff / 86400))d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yy"
        return formatter.string(from: date)
    }

    static func timeString(from isoString: String) -> String {
        guard let date = parseDate(isoString) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
