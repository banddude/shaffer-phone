import SwiftUI

@main
struct TwilioOfficePhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

private struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voiceManager = TwilioVoiceManager.shared
    @State private var selectedTab: Int = 0
    @State private var selectedConversation: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            PhoneView()
                .tabItem {
                    Image(systemName: "phone.fill")
                    Text("Phone")
                }
                .tag(0)

            SMSRootView(selectedConversation: $selectedConversation)
                .tabItem {
                    Image(systemName: "message.fill")
                    Text("Messages")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
                .tag(2)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSMSConversation)) { notification in
            guard let number = notification.userInfo?["number"] as? String else {
                return
            }
            selectedConversation = number
            selectedTab = 1
        }
        .onChange(of: voiceManager.isInCall) { isInCall in
            if isInCall {
                selectedTab = 0
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, voiceManager.isInCall {
                selectedTab = 0
            }
        }
    }
}
