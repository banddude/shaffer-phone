import SwiftUI
import PhotosUI
import AVKit
import AVFoundation

struct SMSRootView: View {
    @StateObject private var listViewModel = SMSListViewModel()
    @Binding var selectedConversation: String?
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if let number = selectedConversation {
                    SMSChatView(number: number) {
                        selectedConversation = nil
                    }
                } else {
                    conversationsList
                }
            }
            .navigationTitle(selectedConversation == nil ? "Messages" : "")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                listViewModel.startPolling()
            }
            .onDisappear {
                if selectedConversation == nil {
                    listViewModel.stopPolling()
                }
            }
            .onChange(of: searchText) { newValue in
                listViewModel.currentFilter = newValue
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSMSConversation)) { notification in
                guard let number = notification.userInfo?["number"] as? String else {
                    return
                }
                selectedConversation = number
            }
        }
    }

    private var conversationsList: some View {
        List {
            Section {
                HStack {
                    TextField("Phone number", text: $searchText)
                        .keyboardType(.phonePad)
                    Button("Open") {
                        let normalized = AppConfig.normalizeDialDestination(searchText) ?? searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalized.isEmpty else {
                            return
                        }
                        selectedConversation = normalized
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if listViewModel.isLoading && listViewModel.conversations.isEmpty {
                ProgressView("Loading...")
            } else if listViewModel.filteredConversations.isEmpty {
                Text("No messages")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(listViewModel.filteredConversations) { conversation in
                    Button {
                        selectedConversation = conversation.number
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(conversation.formattedNumber)
                                    .font(.headline)
                                if conversation.hasMedia {
                                    Text("MMS")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                                Spacer()
                                Text(conversation.relativeTime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(conversation.lastMessage.isEmpty ? "Media message" : conversation.lastMessage)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .refreshable {
            listViewModel.fetchConversations()
        }
    }
}

private struct SMSChatView: View {
    @StateObject private var chatViewModel: SMSChatViewModel
    @StateObject private var keyboardResponder = KeyboardResponder()
    @State private var showMediaPicker = false
    @State private var presentedVideo: PresentedVideo?

    let onBack: () -> Void

    init(number: String, onBack: @escaping () -> Void) {
        _chatViewModel = StateObject(wrappedValue: SMSChatViewModel(number: number))
        self.onBack = onBack
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                messagesList
                Divider()
                composeBar
                    .padding(.bottom, keyboardBottomPadding(for: proxy))
                    .animation(.easeOut(duration: 0.20), value: keyboardResponder.currentHeight)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showMediaPicker) {
            MediaPicker(filter: .any(of: [.images, .videos]), limit: 10) { results in
                chatViewModel.handlePickedMedia(results: results)
            }
        }
        .sheet(item: $presentedVideo) { item in
            SMSVideoPlayerSheet(url: item.url)
        }
        .onDisappear {
            chatViewModel.stopPolling()
        }
    }

    private func keyboardBottomPadding(for proxy: GeometryProxy) -> CGFloat {
        max(0, keyboardResponder.currentHeight - proxy.safeAreaInsets.bottom)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(chatViewModel.formattedNumber)
                    .font(.headline)
                Text("SMS / MMS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chatViewModel.isLoading && chatViewModel.messages.isEmpty {
                        ProgressView()
                            .padding(.top, 30)
                    }

                    ForEach(chatViewModel.messages) { message in
                        SMSBubbleView(
                            message: message,
                            localMediaResolver: { media in
                                chatViewModel.localURL(for: media)
                            },
                            onVideoTap: { url in
                                presentedVideo = PresentedVideo(url: url)
                            }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chatViewModel.messages.count) { _ in
                if let lastId = chatViewModel.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let lastId = chatViewModel.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    private var composeBar: some View {
        VStack(spacing: 8) {
            if !chatViewModel.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(chatViewModel.attachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                SMSDraftAttachmentView(attachment: attachment)
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                Button {
                                    chatViewModel.removeAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.75))
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            HStack(spacing: 8) {
                Button {
                    showMediaPicker = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                }
                .disabled(chatViewModel.isSending)

                TextField("Message", text: $chatViewModel.messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .lineLimit(1...4)

                Button {
                    chatViewModel.sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(sendEnabled ? .blue : .gray)
                }
                .disabled(!sendEnabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var sendEnabled: Bool {
        (!chatViewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chatViewModel.attachments.isEmpty)
            && !chatViewModel.isSending
    }
}

private struct SMSBubbleView: View {
    let message: SMSMessageItem
    let localMediaResolver: (SMSMedia) -> URL?
    let onVideoTap: (URL) -> Void

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer(minLength: 56)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
                if !message.media.isEmpty {
                    ForEach(message.media.indices, id: \.self) { index in
                        let media = message.media[index]
                        if media.isImage {
                            SMSImageMediaView(remoteURL: URL(string: media.url), localURL: localMediaResolver(media))
                        } else if media.isVideo {
                            SMSVideoMediaView(remoteURL: URL(string: media.url), localURL: localMediaResolver(media), onTap: onVideoTap)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: media.isAudio ? "waveform" : "doc.fill")
                                Text(media.contentType)
                                    .font(.caption)
                            }
                            .padding(8)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if !message.body.isEmpty {
                    Text(message.body)
                        .font(.body)
                        .foregroundStyle(message.isOutgoing ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.isOutgoing ? Color.blue : Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                Text(message.formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.isOutgoing {
                Spacer(minLength: 56)
            }
        }
    }
}

private struct SMSImageMediaView: View {
    let remoteURL: URL?
    let localURL: URL?

    var body: some View {
        Group {
            if let localURL,
               let image = UIImage(contentsOfFile: localURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let remoteURL {
                AsyncImage(url: remoteURL) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(ProgressView())
                }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
            }
        }
        .frame(maxWidth: 230, maxHeight: 230)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SMSVideoMediaView: View {
    let remoteURL: URL?
    let localURL: URL?
    let onTap: (URL) -> Void

    @State private var thumbnail: UIImage?

    private var effectiveURL: URL? {
        localURL ?? remoteURL
    }

    var body: some View {
        Button {
            if let url = effectiveURL {
                onTap(url)
            }
        } label: {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 230, height: 145)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 230, height: 145)
                        .overlay(ProgressView())
                }

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onAppear {
            generateThumbnailIfNeeded()
        }
    }

    private func generateThumbnailIfNeeded() {
        guard thumbnail == nil, let sourceURL = effectiveURL else {
            return
        }

        Task.detached {
            let asset = AVURLAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                let image = UIImage(cgImage: cgImage)
                await MainActor.run {
                    thumbnail = image
                }
            }
        }
    }
}

private struct SMSVideoPlayerSheet: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .onDisappear { player.pause() }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            configureAudioSessionForPlayback()
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            deactivateAudioSession()
        }
    }

    private func configureAudioSessionForPlayback() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true, options: [])
        } catch {
            AppLog.error("Video audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            AppLog.error("Video audio session deactivation failed: \(error.localizedDescription)")
        }
    }
}

private struct SMSDraftAttachmentView: View {
    let attachment: SMSDraftAttachment
    @State private var videoThumbnail: UIImage?

    var body: some View {
        ZStack {
            if attachment.isVideo {
                Group {
                    if let thumbnail = videoThumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(ProgressView())
                    }
                }
                .overlay(
                    Image(systemName: "video.fill")
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                )
            } else if let image = UIImage(contentsOfFile: attachment.localURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.2))
            }
        }
        .clipped()
        .onAppear {
            if attachment.isVideo {
                loadVideoThumbnail()
            }
        }
    }

    private func loadVideoThumbnail() {
        guard videoThumbnail == nil else {
            return
        }

        Task.detached {
            let asset = AVURLAsset(url: attachment.localURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            if let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
                let image = UIImage(cgImage: cgImage)
                await MainActor.run {
                    videoThumbnail = image
                }
            }
        }
    }
}

private struct PresentedVideo: Identifiable {
    let id = UUID().uuidString
    let url: URL
}

private struct MediaPicker: UIViewControllerRepresentable {
    let filter: PHPickerFilter
    let limit: Int
    let onFinish: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = filter
        configuration.selectionLimit = limit
        configuration.preferredAssetRepresentationMode = .current

        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onFinish: ([PHPickerResult]) -> Void

        init(onFinish: @escaping ([PHPickerResult]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onFinish(results)
        }
    }
}
