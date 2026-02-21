import Foundation
import UserNotifications

final class SMSListViewModel: ObservableObject {
    @Published var conversations: [SMSConversation] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var currentFilter: String = ""

    private var timer: Timer?
    private var hasCompletedInitialLoad = false
    private var lastSeenConversationTimestamp: [String: String] = [:]
    private var notifiedMessageIds: Set<String> = []
    private let notifiedMessageIdsKey = "sms_notified_message_ids"

    init() {
        loadNotifiedMessageIds()
        fetchConversations()
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    var filteredConversations: [SMSConversation] {
        if currentFilter.isEmpty {
            return conversations
        }
        return conversations.filter { conversation in
            conversation.number.contains(currentFilter)
            || conversation.formattedNumber.localizedCaseInsensitiveContains(currentFilter)
            || conversation.lastMessage.localizedCaseInsensitiveContains(currentFilter)
        }
    }

    func fetchConversations() {
        guard let url = AppConfig.apiURL("/api/messages") else {
            return
        }

        if conversations.isEmpty {
            isLoading = true
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.isLoading = false

                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard let data else {
                    self.errorMessage = "No data received"
                    return
                }

                do {
                    let decoded = try JSONDecoder().decode(SMSConversationsResponse.self, from: data)
                    let sorted = decoded.conversations.sorted { $0.lastTimestamp > $1.lastTimestamp }
                    self.detectNewInboundMessages(in: sorted)
                    self.conversations = sorted
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = "Failed to parse conversations"
                }
            }
        }.resume()
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: AppConfig.pollingInterval, repeats: true) { [weak self] _ in
            self?.fetchConversations()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func detectNewInboundMessages(in conversations: [SMSConversation]) {
        if !hasCompletedInitialLoad {
            for conversation in conversations {
                lastSeenConversationTimestamp[conversation.number] = conversation.lastTimestamp
            }
            hasCompletedInitialLoad = true
            return
        }

        for conversation in conversations {
            let previous = lastSeenConversationTimestamp[conversation.number]
            lastSeenConversationTimestamp[conversation.number] = conversation.lastTimestamp
            if previous == nil || previous == conversation.lastTimestamp {
                continue
            }
            checkForInboundNotification(number: conversation.number)
        }
    }

    private func checkForInboundNotification(number: String) {
        guard let url = AppConfig.apiURL("/api/messages", queryItems: [URLQueryItem(name: "number", value: number)]) else {
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else {
                return
            }
            guard let decoded = try? JSONDecoder().decode(SMSMessagesResponse.self, from: data) else {
                return
            }
            guard let lastInbound = decoded.messages.last(where: { $0.direction == "inbound" }) else {
                return
            }
            guard !self.notifiedMessageIds.contains(lastInbound.id) else {
                return
            }

            self.notifiedMessageIds.insert(lastInbound.id)
            self.persistNotifiedMessageIds()
            self.scheduleNotification(for: number, message: lastInbound)
        }.resume()
    }

    private func scheduleNotification(for number: String, message: SMSMessageItem) {
        guard AppConfig.enableLocalPollingNotifications else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = SMSUtils.formatPhoneNumber(number)
        content.body = message.body.isEmpty ? "Media message" : message.body
        content.sound = .default
        content.userInfo = [
            "sms_number": number,
            "sms_message_id": message.id
        ]

        let request = UNNotificationRequest(identifier: "sms-\(message.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func loadNotifiedMessageIds() {
        let stored = UserDefaults.standard.stringArray(forKey: notifiedMessageIdsKey) ?? []
        notifiedMessageIds = Set(stored)
    }

    private func persistNotifiedMessageIds() {
        let limited = Array(notifiedMessageIds.prefix(500))
        UserDefaults.standard.set(limited, forKey: notifiedMessageIdsKey)
        notifiedMessageIds = Set(limited)
    }
}
