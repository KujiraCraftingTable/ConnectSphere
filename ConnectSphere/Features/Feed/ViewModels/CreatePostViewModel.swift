import Foundation
import PhotosUI
import SwiftUI
import UserNotifications
import AVFoundation

/// Media picked for a post: image (upload as jpeg) or video (upload as mp4/mov file)
struct PickedPostMedia: Identifiable {
    let id = UUID()
    let image: UIImage?     // original image (nil if this is a video)
    let videoURL: URL?      // temp video file in the sandbox (nil if this is an image)
    let thumbnail: UIImage? // video's first frame, for preview

    var isVideo: Bool { videoURL != nil }
    var previewImage: UIImage? { image ?? thumbnail }
}

/// Copies a video file from PhotosPicker into a temp dir for multipart upload
private struct PostMediaFileTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            try? FileManager.default.copyItem(at: received.file, to: dest)
            return PostMediaFileTransferable(url: dest)
        }
    }
}

@MainActor
@Observable
class CreatePostViewModel {
    var isPosting = false
    var isFetchingLink = false
    var isUploadingMedia = false
    var linkPreview: LinkPreviewDTO? = nil

    private let repository     = PostRepository()
    private let notifRepository = UserNotificationRepository()
    private var linkPreviewTask: Task<Void, Never>? = nil

    // MARK: - Link preview (debounced)

    func detectAndFetchLink(_ text: String) {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches  = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let urlString = matches?.first?.url?.absoluteString else {
            if linkPreview != nil { linkPreview = nil }
            return
        }
        if linkPreview?.url == urlString { return }

        linkPreviewTask?.cancel()
        linkPreviewTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            isFetchingLink = true
            linkPreview = try? await repository.fetchLinkPreview(url: urlString)
            isFetchingLink = false
        }
    }

    // MARK: - Media upload

    /// Image → decode to UIImage; video → copy to a temp file + generate a thumbnail.
    /// An item that fails to load is silently skipped.
    func loadSelectedMedia(_ items: [PhotosPickerItem]) async -> [PickedPostMedia] {
        var result: [PickedPostMedia] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                result.append(PickedPostMedia(image: image, videoURL: nil, thumbnail: nil))
            } else if let file = try? await item.loadTransferable(type: PostMediaFileTransferable.self) {
                let thumbnail = await Self.videoThumbnail(for: file.url)
                result.append(PickedPostMedia(image: nil, videoURL: file.url, thumbnail: thumbnail))
            }
        }
        return result
    }

    func uploadImage(_ image: UIImage) async -> String? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        return try? await repository.uploadImage(data)
    }

    /// Uploads all selected media in order; a failed item is skipped, order is preserved
    func uploadMedia(_ media: [PickedPostMedia]) async -> [String] {
        isUploadingMedia = true
        defer { isUploadingMedia = false }
        var urls: [String] = []
        for item in media {
            if let image = item.image {
                if let url = await uploadImage(image) { urls.append(url) }
            } else if let fileURL = item.videoURL {
                if let url = try? await repository.uploadVideo(fileURL: fileURL) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    /// The video's first frame, used as the thumbnail preview in the composer
    nonisolated private static func videoThumbnail(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, _ in
                continuation.resume(returning: cgImage.map(UIImage.init(cgImage:)))
            }
        }
    }

    // MARK: - Submit

    /// Updates an existing post.
    func updatePost(
        postId: String,
        content: String,
        privacy: PostPrivacy,
        selectedMedia: [PickedPostMedia],
        existingImageUrls: [String],
        onSuccess: @escaping (Post) -> Void
    ) {
        let capturedPreview = linkPreview

        Task {
            isPosting = true
            defer { isPosting = false }

            // New media selected → replace all of it; none selected → keep the old media
            let imageUrls: [String]
            if !selectedMedia.isEmpty {
                imageUrls = await uploadMedia(selectedMedia)
            } else {
                imageUrls = existingImageUrls
            }

            // Link post: the link's thumbnail still goes through image_url, as before
            let imageUrl = capturedPreview?.image

            let updatedPost = try? await repository.updatePost(
                postId: postId,
                content: content,
                privacy: privacy,
                imageUrl: imageUrl,
                imageUrls: imageUrls,
                linkUrl: capturedPreview?.url,
                articleTitle: capturedPreview?.title
            )
            if let post = updatedPost {
                onSuccess(post)
            }
        }
    }

    /// Posts immediately, without waiting on AI. Passes the newly created post (in full)
    /// to the caller via `onSuccess` so it can be inserted straight at the top of the
    /// feed — no need to wait for a separate reload to see your own post. After posting,
    /// a background task waits 10 seconds then checks whether the backend created a mode
    /// mismatch notification. (AI-generated tags are never surfaced on the client, so
    /// there is nothing to refetch once the post is created.)
    func submitPost(
        content: String,
        mode: AppMode,
        privacy: PostPrivacy,
        authToken: String?,
        selectedMedia: [PickedPostMedia],
        hashtags: [String] = [],
        onSuccess: @escaping (Post) -> Void
    ) {
        var finalContent = content.trimmingCharacters(in: .whitespaces)
        let capturedPreview = linkPreview

        if capturedPreview != nil {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let matches = detector?.matches(in: finalContent, range: NSRange(finalContent.startIndex..., in: finalContent))
            for match in (matches ?? []).reversed() {
                if let range = Range(match.range, in: finalContent) {
                    finalContent = finalContent.replacingCharacters(in: range, with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        guard !finalContent.isEmpty || capturedPreview != nil || !selectedMedia.isEmpty else { return }

        Task {
            isPosting = true
            defer { isPosting = false }

            // Upload ALL selected media (images + video);
            // for a link post with no media, the link's thumbnail goes through image_url
            let imageUrls = selectedMedia.isEmpty ? [] : await uploadMedia(selectedMedia)
            let imageUrl: String? = selectedMedia.isEmpty ? capturedPreview?.image : nil

            guard let post = try? await repository.createPost(
                content: finalContent.isEmpty ? " " : finalContent,
                mode: mode,
                privacy: privacy,
                imageUrl: imageUrl,
                imageUrls: imageUrls,
                linkUrl: capturedPreview?.url,
                articleTitle: capturedPreview?.title,
                hashtags: hashtags
            ) else {
                return
            }
            let postId = post.id

            onSuccess(post)

            // Background: check the mismatch notification after 10 seconds
            if let token = authToken {
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    await self.checkAndNotifyMismatch(postId: postId, token: token)
                }
            }
        }
    }

    // MARK: - Private

    /// Fetches the notification from the backend; if there's a mismatch, shows an iOS local notification banner.
    private func checkAndNotifyMismatch(postId: String, token: String) async {
        // Respect the "AI post suggestions" toggle in Notification settings
        let aiNotifsEnabled = (UserDefaults.standard.object(forKey: "aiSuggestionNotifsEnabled") as? Bool) ?? true
        guard aiNotifsEnabled else { return }
        guard let notif = try? await notifRepository.fetchMismatchFor(postId: postId, token: token) else { return }

        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

        let b = Bundle.app
        let content = UNMutableNotificationContent()
        content.title = b.loc("AI suggestions")
        let modeName = notif.payload.suggestedMode == "hobby" ? b.loc("Hobby") : b.loc("Work")
        content.body = notif.payload.reason
            ?? String(format: b.loc("This post may fit %@ mode better"), modeName)
        content.sound = .default
        content.userInfo = ["notification_id": notif.id, "screen": "notifications"]

        let request = UNNotificationRequest(
            identifier: "mode_mismatch_\(notif.id)",
            content: content,
            trigger: nil // deliver immediately
        )
        try? await center.add(request)
    }
}
