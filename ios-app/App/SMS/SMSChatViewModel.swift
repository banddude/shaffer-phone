import Foundation
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation

final class SMSChatViewModel: ObservableObject {
    @Published var messages: [SMSMessageItem] = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var messageText: String = ""
    @Published var attachments: [SMSDraftAttachment] = []
    @Published private(set) var localMediaCache: [String: URL] = [:]

    let number: String
    private var timer: Timer?

    init(number: String) {
        self.number = number
        fetchMessages()
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    var formattedNumber: String {
        SMSUtils.formatPhoneNumber(number)
    }

    func fetchMessages() {
        guard let url = AppConfig.apiURL("/api/messages", queryItems: [
            URLQueryItem(name: "number", value: number)
        ]) else {
            return
        }

        if messages.isEmpty {
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
                    return
                }

                do {
                    let decoded = try JSONDecoder().decode(SMSMessagesResponse.self, from: data)
                    self.messages = decoded.messages
                    self.cacheMediaForMessages(decoded.messages)
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = "Failed to parse messages"
                }
            }
        }.resume()
    }

    func sendMessage() {
        let body = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftAttachments = attachments
        guard !body.isEmpty || !draftAttachments.isEmpty else {
            return
        }

        guard let url = AppConfig.apiURL("/send-sms") else {
            return
        }

        isSending = true

        let sentText = body
        let sentAttachments = draftAttachments
        messageText = ""
        attachments = []

        Task.detached { [weak self] in
            guard let self else {
                return
            }

            do {
                let uploaded = try await self.uploadAttachmentsIfNeeded(sentAttachments)
                try await self.performSendMessage(url: url, body: sentText, mediaURLs: uploaded.map { $0.url })
                await MainActor.run {
                    self.isSending = false
                    self.errorMessage = nil
                    self.fetchMessages()
                }
            } catch {
                await MainActor.run {
                    self.isSending = false
                    self.errorMessage = error.localizedDescription
                    self.messageText = sentText
                    self.attachments = sentAttachments
                }
            }
        }
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: AppConfig.pollingInterval, repeats: true) { [weak self] _ in
            self?.fetchMessages()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func removeAttachment(_ attachment: SMSDraftAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func localURL(for media: SMSMedia) -> URL? {
        localMediaCache[media.url]
    }

    func handlePickedMedia(results: [PHPickerResult]) {
        guard !results.isEmpty else {
            return
        }

        let dispatchGroup = DispatchGroup()
        var picked: [SMSDraftAttachment] = []
        let lock = NSLock()

        for result in results {
            let provider = result.itemProvider

            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                dispatchGroup.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let source = url,
                          let copied = self.copyToDraftMedia(sourceURL: source, preferredExtension: "mov") else {
                        dispatchGroup.leave()
                        return
                    }
                    self.transcodeVideoForMMS(sourceURL: copied) { transcodedURL in
                        let localURL = transcodedURL ?? copied
                        let attachment = SMSDraftAttachment(
                            localURL: localURL,
                            contentType: self.guessContentType(for: localURL, fallback: "video/mp4")
                        )
                        lock.lock()
                        picked.append(attachment)
                        lock.unlock()
                        dispatchGroup.leave()
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                dispatchGroup.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    defer { dispatchGroup.leave() }
                    guard let source = url,
                          let copied = self.copyToDraftMedia(sourceURL: source, preferredExtension: "jpg") else {
                        return
                    }
                    let attachment = SMSDraftAttachment(
                        localURL: copied,
                        contentType: self.guessContentType(for: copied, fallback: "image/jpeg")
                    )
                    lock.lock()
                    picked.append(attachment)
                    lock.unlock()
                }
            }
        }

        dispatchGroup.notify(queue: .main) {
            self.attachments.append(contentsOf: picked)
        }
    }

    private func copyToDraftMedia(sourceURL: URL, preferredExtension: String) -> URL? {
        let ext = sourceURL.pathExtension.isEmpty ? preferredExtension : sourceURL.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("sms_draft_\(UUID().uuidString).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func cacheMediaForMessages(_ messages: [SMSMessageItem]) {
        let mediaItems = messages.flatMap { $0.media }.filter { $0.isImage || $0.isVideo }
        for media in mediaItems {
            if localMediaCache[media.url] != nil {
                continue
            }
            guard let remoteURL = URL(string: media.url) else {
                continue
            }

            Task.detached { [weak self] in
                guard let self else {
                    return
                }
                do {
                    let (data, _) = try await URLSession.shared.data(from: remoteURL)
                    let localURL = try self.persistMediaData(data, from: media)
                    await MainActor.run {
                        self.localMediaCache[media.url] = localURL
                    }
                } catch {
                    // Keep remote fallback URL if local caching fails.
                }
            }
        }
    }

    private func persistMediaData(_ data: Data, from media: SMSMedia) throws -> URL {
        let baseDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SMSMedia", isDirectory: true)
        if !FileManager.default.fileExists(atPath: baseDir.path) {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }

        let fileName = "\(sha256(media.url)).\(media.fileExtension)"
        let destination = baseDir.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func uploadAttachmentsIfNeeded(_ draftAttachments: [SMSDraftAttachment]) async throws -> [SMSUploadedMedia] {
        guard !draftAttachments.isEmpty else {
            return []
        }
        guard let url = AppConfig.apiURL("/upload-media") else {
            throw NSError(domain: "SMSUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var bodyData = Data()

        for attachment in draftAttachments {
            let fileData = try Data(contentsOf: attachment.localURL)
            bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
            bodyData.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(attachment.localURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
            bodyData.append("Content-Type: \(attachment.contentType)\r\n\r\n".data(using: .utf8)!)
            bodyData.append(fileData)
            bodyData.append("\r\n".data(using: .utf8)!)
        }

        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AppConfig.apiToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "SMSUpload", code: -2, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }

        let decoded = try JSONDecoder().decode(SMSUploadResponse.self, from: data)
        guard decoded.success, let files = decoded.files else {
            throw NSError(domain: "SMSUpload", code: -3, userInfo: [NSLocalizedDescriptionKey: decoded.error ?? "Upload failed"])
        }
        return files
    }

    private func performSendMessage(url: URL, body: String, mediaURLs: [String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AppConfig.apiToken)", forHTTPHeaderField: "Authorization")

        var payload: [String: Any] = ["to": number, "body": body]
        if !mediaURLs.isEmpty {
            payload["mediaUrls"] = mediaURLs
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "SMSSend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send message"])
        }

        let decoded = try? JSONDecoder().decode(SMSSendResponse.self, from: data)
        if let errorText = decoded?.error {
            throw NSError(domain: "SMSSend", code: -2, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
    }

    private func guessContentType(for url: URL, fallback: String) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return fallback
    }

    private func transcodeVideoForMMS(sourceURL: URL, completion: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: sourceURL)
        let preferredPreset = AVAssetExportSession.exportPresets(compatibleWith: asset).contains(AVAssetExportPreset1280x720)
            ? AVAssetExportPreset1280x720
            : AVAssetExportPresetMediumQuality

        guard let exporter = AVAssetExportSession(asset: asset, presetName: preferredPreset) else {
            completion(nil)
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sms_video_\(UUID().uuidString).mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = exporter.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        exporter.shouldOptimizeForNetworkUse = true

        exporter.exportAsynchronously {
            switch exporter.status {
            case .completed:
                completion(outputURL)
            default:
                completion(nil)
            }
        }
    }
}

struct SMSDraftAttachment: Identifiable {
    let id = UUID().uuidString
    let localURL: URL
    let contentType: String

    var isVideo: Bool {
        contentType.hasPrefix("video/")
    }
}

struct SMSUploadResponse: Codable {
    let success: Bool
    let files: [SMSUploadedMedia]?
    let error: String?
}

struct SMSUploadedMedia: Codable {
    let key: String?
    let url: String
    let contentType: String
    let fileName: String?
    let size: Int?
}
