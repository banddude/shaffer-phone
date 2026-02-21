import SwiftUI
import UIKit
import Contacts
import ContactsUI

struct PhoneView: View {
    @StateObject private var voiceManager = TwilioVoiceManager.shared
    @StateObject private var contactLookup = ContactLookupService()
    @State private var phoneNumber: String = ""
    @State private var showInCallKeypad: Bool = false
    @State private var showCallHistory: Bool = false
    @State private var showContactPicker: Bool = false

    private let keypadRows: [[DialPadDigit]] = [
        [.init("1", ""), .init("2", "ABC"), .init("3", "DEF")],
        [.init("4", "GHI"), .init("5", "JKL"), .init("6", "MNO")],
        [.init("7", "PQRS"), .init("8", "TUV"), .init("9", "WXYZ")],
        [.init("*", ""), .init("0", "+"), .init("#", "")]
    ]

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                Group {
                    if voiceManager.isInCall {
                        inCallContent(
                            safeAreaTop: geo.safeAreaInsets.top,
                            safeAreaBottom: geo.safeAreaInsets.bottom
                        )
                    } else {
                        dialerContent(safeAreaBottom: geo.safeAreaInsets.bottom)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: voiceManager.isInCall)
            }
            .navigationTitle(voiceManager.isInCall ? "" : "Phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(voiceManager.isInCall ? .hidden : .visible, for: .navigationBar)
            .toolbar(voiceManager.isInCall ? .hidden : .visible, for: .tabBar)
            .background(voiceManager.isInCall ? Color.black : Color(uiColor: .systemGroupedBackground))
            .toolbar {
                if !voiceManager.isInCall {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            hapticTap(style: .light)
                            showCallHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
            }
        }
        .onChange(of: voiceManager.isInCall) { isInCall in
            if !isInCall {
                showInCallKeypad = false
            }
        }
        .sheet(isPresented: $showCallHistory) {
            CallHistoryView(
                voiceManager: voiceManager,
                contactLookup: contactLookup,
                onCallBack: { number in
                    phoneNumber = number
                    voiceManager.startOutgoingCall(rawDestination: number)
                }
            )
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPhonePicker { selectedNumber in
                let trimmed = selectedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return
                }
                phoneNumber = trimmed
                hapticTap(style: .medium)
                voiceManager.startOutgoingCall(rawDestination: trimmed)
            }
        }
        .onAppear {
            contactLookup.resolveContacts(for: voiceManager.callHistory.map(\.remote))
            contactLookup.resolveContacts(for: [voiceManager.activeRemote])
        }
        .onChange(of: voiceManager.callHistory.count) { _ in
            contactLookup.resolveContacts(for: voiceManager.callHistory.map(\.remote))
        }
        .onChange(of: voiceManager.activeRemote) { value in
            contactLookup.resolveContacts(for: [value])
        }
    }

    private func dialerContent(safeAreaBottom: CGFloat) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(displayNumber)
                    .font(.system(size: 34, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(height: 54)

            dialPad(onTap: { digit in
                phoneNumber += digit.number
            })

            HStack(spacing: 28) {
                Button {
                    hapticTap(style: .light)
                    showContactPicker = true
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                }

                Button {
                    hapticTap(style: .medium)
                    voiceManager.startOutgoingCall(rawDestination: phoneNumber)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 86, height: 86)
                        .background(Color.green)
                        .clipShape(Circle())
                }
                .disabled(phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    if !phoneNumber.isEmpty {
                        _ = phoneNumber.removeLast()
                    }
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(phoneNumber.isEmpty ? Color.gray : Color.primary)
                        .frame(width: 56, height: 56)
                }
                .disabled(phoneNumber.isEmpty)
            }
            .padding(.top, 6)

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 74 + safeAreaBottom)
    }

    private func inCallContent(safeAreaTop: CGFloat, safeAreaBottom: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.08, blue: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: safeAreaTop + 8)

                VStack(spacing: 10) {
                    Text(voiceManager.callStatus.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .tracking(1.1)

                    Text(callRemoteLabel)
                        .font(.system(size: 42, weight: .regular, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

                if isIncomingCallUI {
                    incomingCallActions
                    Spacer(minLength: 16)
                } else {
                    if showInCallKeypad {
                        inCallKeypad
                    } else {
                        inCallControlGrid
                    }

                    Spacer(minLength: 16)

                    Button {
                        hapticTap(style: .medium)
                        voiceManager.endActiveCall()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 86, height: 86)
                            .background(Color(red: 0.95, green: 0.15, blue: 0.19))
                            .clipShape(Circle())
                    }
                    .padding(.bottom, max(22, safeAreaBottom + 6))
                }
            }
        }
    }

    private func dialPad(onTap: @escaping (DialPadDigit) -> Void) -> some View {
        VStack(spacing: 12) {
            ForEach(keypadRows.indices, id: \.self) { rowIndex in
                HStack(spacing: 18) {
                    ForEach(keypadRows[rowIndex], id: \.number) { digit in
                        Button {
                            onTap(digit)
                        } label: {
                            VStack(spacing: 2) {
                                Text(digit.number)
                                    .font(.system(size: 36, weight: .regular, design: .rounded))
                                    .foregroundStyle(.primary)
                                Text(digit.letters)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .tracking(1.0)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 12)
                            }
                            .frame(width: 84, height: 84)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var inCallControlGrid: some View {
        let actions: [InCallAction] = [
            .init(
                title: "Speaker",
                symbol: voiceManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                isActive: voiceManager.isSpeakerOn,
                isEnabled: true,
                action: {
                    hapticTap(style: .light)
                    voiceManager.toggleSpeaker()
                }
            ),
            .init(
                title: "Add Call",
                symbol: "plus",
                isActive: false,
                isEnabled: false,
                action: {}
            ),
            .init(
                title: "Mute",
                symbol: voiceManager.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: voiceManager.isMuted,
                isEnabled: true,
                action: {
                    hapticTap(style: .light)
                    voiceManager.toggleMute()
                }
            ),
            .init(
                title: "...",
                symbol: "ellipsis",
                isActive: false,
                isEnabled: false,
                action: {}
            ),
            .init(
                title: "Hold",
                symbol: voiceManager.isOnHold ? "pause.fill" : "pause",
                isActive: voiceManager.isOnHold,
                isEnabled: true,
                action: {
                    hapticTap(style: .light)
                    voiceManager.toggleHold()
                }
            ),
            .init(
                title: "Keypad",
                symbol: "circle.grid.3x3.fill",
                isActive: showInCallKeypad,
                isEnabled: true,
                action: {
                    hapticTap(style: .light)
                    showInCallKeypad.toggle()
                }
            )
        ]

        return LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            alignment: .center,
            spacing: 24
        ) {
            ForEach(actions) { item in
                inCallActionButton(item)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var inCallKeypad: some View {
        VStack(spacing: 14) {
            VStack(spacing: 14) {
                ForEach(keypadRows.indices, id: \.self) { rowIndex in
                    HStack(spacing: 18) {
                        ForEach(keypadRows[rowIndex], id: \.number) { digit in
                            Button {
                                voiceManager.sendDTMF(digit.number)
                            } label: {
                                VStack(spacing: 2) {
                                    Text(digit.number)
                                        .font(.system(size: 37, weight: .regular, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text(digit.letters)
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.68))
                                        .tracking(1.0)
                                        .frame(height: 11)
                                }
                                .frame(width: 82, height: 82)
                                .background(Color.white.opacity(0.16))
                                .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button {
                hapticTap(style: .light)
                showInCallKeypad = false
            } label: {
                Text("Hide Keypad")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var incomingCallActions: some View {
        HStack(spacing: 56) {
            Button {
                hapticNotification(type: .warning)
                voiceManager.declineIncomingCall()
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 86, height: 86)
                        .background(Color(red: 0.95, green: 0.15, blue: 0.19))
                        .clipShape(Circle())

                    Text("Decline")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
            }
            .buttonStyle(.plain)

            Button {
                hapticNotification(type: .success)
                voiceManager.answerIncomingCall()
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 86, height: 86)
                        .background(Color(red: 0.19, green: 0.76, blue: 0.34))
                        .clipShape(Circle())

                    Text("Answer")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 34)
    }

    private func inCallActionButton(_ item: InCallAction) -> some View {
        Button(action: item.action) {
            VStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(item.isEnabled ? .white : Color.white.opacity(0.5))
                    .frame(width: 78, height: 78)
                    .background(item.isActive ? Color.white.opacity(0.30) : Color.white.opacity(0.18))
                    .clipShape(Circle())

                Text(item.title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(item.isEnabled ? Color.white : Color.white.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.75)
    }

    private var displayNumber: String {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter Number"
        }
        return trimmed
    }

    private var callRemoteLabel: String {
        let trimmed = voiceManager.activeRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Active Call"
        }
        return contactLookup.displayName(for: trimmed)
    }

    private var isIncomingCallUI: Bool {
        voiceManager.callStatus.caseInsensitiveCompare("Incoming") == .orderedSame
    }

    private func hapticTap(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    private func hapticNotification(type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

private struct InCallAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void
}

private struct DialPadDigit {
    let number: String
    let letters: String

    init(_ number: String, _ letters: String) {
        self.number = number
        self.letters = letters
    }
}

private struct CallHistoryView: View {
    @ObservedObject var voiceManager: TwilioVoiceManager
    @ObservedObject var contactLookup: ContactLookupService
    let onCallBack: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if voiceManager.callHistory.isEmpty {
                    VStack(spacing: 10) {
                        Text("No recent calls")
                            .font(.headline)
                        Text("Calls you place or receive will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                } else {
                    List(voiceManager.callHistory) { entry in
                        CallHistoryRow(
                            entry: entry,
                            displayName: contactLookup.displayName(for: entry.remote),
                            onCallBack: {
                                onCallBack(entry.remote)
                                dismiss()
                            }
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Recents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !voiceManager.callHistory.isEmpty {
                        Button("Clear") {
                            voiceManager.clearCallHistory()
                        }
                    }
                }
            }
            .onAppear {
                contactLookup.resolveContacts(
                    for: voiceManager.callHistory.map(\.remote)
                )
            }
            .onChange(of: voiceManager.callHistory.count) { _ in
                contactLookup.resolveContacts(
                    for: voiceManager.callHistory.map(\.remote)
                )
            }
        }
    }
}

private struct CallHistoryRow: View {
    let entry: VoiceCallHistoryEntry
    let displayName: String
    let onCallBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onCallBack) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.green)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        if entry.direction == .outbound {
            return "arrow.up.right.circle.fill"
        }
        if entry.result == "Missed" || entry.result == "Declined" {
            return "phone.badge.xmark.fill"
        }
        return "arrow.down.left.circle.fill"
    }

    private var iconColor: Color {
        if entry.result == "Failed" || entry.result == "Missed" || entry.result == "Declined" {
            return .red
        }
        if entry.direction == .outbound {
            return .blue
        }
        return .green
    }

    private var subtitleText: String {
        let timeText = entry.endedAt.formatted(date: .abbreviated, time: .shortened)
        if entry.durationSeconds > 0 {
            return "\(entry.result), \(formattedDuration(entry.durationSeconds)), \(timeText)"
        }
        return "\(entry.result), \(timeText)"
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private final class ContactLookupService: ObservableObject {
    @Published private var namesByNumber: [String: String] = [:]
    private let store = CNContactStore()

    func displayName(for number: String) -> String {
        let normalized = normalize(number)
        return namesByNumber[normalized] ?? number
    }

    func resolveContacts(for numbers: [String]) {
        let unique = Set(numbers.map(normalize)).filter { !$0.isEmpty }
        guard !unique.isEmpty else {
            return
        }
        let unresolved = unique.filter { namesByNumber[$0] == nil }
        guard !unresolved.isEmpty else {
            return
        }

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            lookupContacts(for: Array(unresolved))
        case .notDetermined:
            store.requestAccess(for: .contacts) { [weak self] granted, _ in
                guard granted else {
                    return
                }
                self?.lookupContacts(for: Array(unresolved))
            }
        default:
            return
        }
    }

    private func lookupContacts(for normalizedNumbers: [String]) {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor
        ]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            var updates: [String: String] = [:]

            for normalized in normalizedNumbers where updates[normalized] == nil {
                for candidate in self.lookupCandidates(for: normalized) {
                    let predicate = CNContact.predicateForContacts(
                        matching: CNPhoneNumber(stringValue: candidate)
                    )
                    guard let contact = try? self.store.unifiedContacts(
                        matching: predicate,
                        keysToFetch: keys
                    ).first else {
                        continue
                    }

                    let fullName = self.bestName(for: contact)
                    if !fullName.isEmpty {
                        updates[normalized] = fullName
                        break
                    }
                }
            }

            guard !updates.isEmpty else {
                return
            }
            DispatchQueue.main.async {
                for (number, name) in updates {
                    self.namesByNumber[number] = name
                }
            }
        }
    }

    private func lookupCandidates(for normalized: String) -> [String] {
        var candidates: [String] = [normalized]
        if normalized.hasPrefix("1"), normalized.count == 11 {
            candidates.append(String(normalized.dropFirst()))
        }
        if normalized.count == 10 {
            candidates.append("1" + normalized)
        }
        return Array(Set(candidates))
    }

    private func bestName(for contact: CNContact) -> String {
        let personName = [contact.givenName, contact.middleName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !personName.isEmpty {
            return personName
        }

        let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !org.isEmpty {
            return org
        }

        return ""
    }

    private func normalize(_ value: String) -> String {
        value.filter(\.isNumber)
    }
}

private struct ContactPhonePicker: UIViewControllerRepresentable {
    let onSelectPhoneNumber: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfContact = NSPredicate(value: false)
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == '\(CNContactPhoneNumbersKey)'")
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let parent: ContactPhonePicker

        init(_ parent: ContactPhonePicker) {
            self.parent = parent
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            guard contactProperty.key == CNContactPhoneNumbersKey,
                  let phoneNumber = contactProperty.value as? CNPhoneNumber else {
                return
            }
            parent.onSelectPhoneNumber(phoneNumber.stringValue)
        }
    }
}
