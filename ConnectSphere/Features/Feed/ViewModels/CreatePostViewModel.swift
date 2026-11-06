import Foundation
import PhotosUI
import SwiftUI
import UserNotifications

/// Media in the composer: freshly picked (image uploaded as jpeg, video as an
/// mp4/mov file) or already uploaded. A draft's media, kept as its URL.
struct PickedPostMedia: Identifiable {
    let id = UUID()
    let image: UIImage?     // original image (nil if this is a video)
    let videoURL: URL?      // temp video file in the sandbox (nil if this is an image)
    let thumbnail: UIImage? // video's first frame, for preview
    /// The photo's bytes as picked (HEIC/JPEG/PNG), so the upload compresses
    /// the original once rather than an already-compressed copy.
    var sourceData: Data? = nil
    /// Already on the server (from a draft): sent back as-is, never re-uploaded.
    var remoteURL: String? = nil
    /// The picker item it came from, so picking more photos keeps this one
    /// (and its alt text) instead of rebuilding it.
    var pickerItem: PhotosPickerItem? = nil
    /// What the photo or video shows. Shown in its place while it loads and
    /// read by VoiceOver. Optional.
    var altText = ""

    var isVideo: Bool {
        if videoURL != nil { return true }
        let ext = remoteURL.flatMap(URL.init(string:))?.pathExtension.lowercased() ?? ""
        return ext == "mp4" || ext == "mov"
    }

    /// A draft's media, with its alt text.
    static func remote(_ urls: [String], alts: [String]) -> [PickedPostMedia] {
        urls.enumerated().map { i, url in
            PickedPostMedia(image: nil, videoURL: nil, thumbnail: nil,
                            remoteURL: url, altText: i < alts.count ? alts[i] : "")
        }
    }
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
    /// Picked photos/videos not loaded yet. The composer shows a blinking
    /// tile for each, so a slow video doesn't look like nothing was picked.
    var pendingMediaCount = 0
    /// Shown by `CreatePostView` when media upload or the post itself fails,
    /// previously both failed silently (the post went out without its video,
    /// or the composer just sat there).
    var errorMessage: String?
    var linkPreview: LinkPreviewDTO? = nil

    private let repository     = PostRepository()
    private let notifRepository = UserNotificationRepository()
    private var linkPreviewTask: Task<Void, Never>? = nil

    // MARK: - Link preview (debounced)

    /// Once the card is up the link lives in the card, so `onLinkShown` lets the
    /// composer take the URL out of the text. The card is therefore not cleared
    /// when the text has no URL. Only its X button (or a new link) replaces it.
    func detectAndFetchLink(_ text: String, onLinkShown: @escaping @MainActor () -> Void) {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches  = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let urlString = matches?.first?.url?.absoluteString else {
            linkPreviewTask?.cancel()
            return
        }
        if linkPreview?.url == urlString { onLinkShown(); return }

        linkPreviewTask?.cancel()
        linkPreviewTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            isFetchingLink = true
            let fetched = try? await repository.fetchLinkPreview(url: urlString)
            isFetchingLink = false
            guard !Task.isCancelled, let fetched else { return }
            linkPreview = fetched
            onLinkShown()
        }
    }

    // MARK: - Media upload

    /// Image → decode to UIImage; video → copy to a temp file + generate a thumbnail.
    /// An item that fails to load is silently skipped. `previous` is what the
    /// composer already shows: a draft's uploaded media stays first, and items
    /// still picked keep their loaded copy and alt text. `progress` gets the
    /// list so far after each new item, so items appear one by one while
    /// `pendingMediaCount` counts down the rest.
    func loadSelectedMedia(_ items: [PhotosPickerItem], keeping previous: [PickedPostMedia] = [],
                           progress: (([PickedPostMedia]) -> Void)? = nil) async -> [PickedPostMedia] {
        var result = previous.filter { $0.remoteURL != nil }
        pendingMediaCount = items.filter { item in !previous.contains { $0.pickerItem == item } }.count
        defer { pendingMediaCount = 0 }
        for item in items {
            if let kept = previous.first(where: { $0.pickerItem == item }) {
                result.append(kept)
                continue
            }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                result.append(PickedPostMedia(image: image, videoURL: nil, thumbnail: nil, sourceData: data, pickerItem: item))
            } else if let file = try? await item.loadTransferable(type: PostMediaFileTransferable.self) {
                let thumbnail = await VideoFrame.firstFrame(of: file.url, maxSide: 600)
                result.append(PickedPostMedia(image: nil, videoURL: file.url, thumbnail: thumbnail, pickerItem: item))
            }
            pendingMediaCount = max(0, pendingMediaCount - 1)
            progress?(result)
        }
        return result
    }

    /// The cleaner resizes and compresses (`MediaSanitizer.cleanImage`), so
    /// it gets the original bytes, or a lossless copy when there are none.
    func uploadImage(_ image: UIImage, original: Data? = nil) async -> String? {
        guard let data = original ?? image.jpegData(compressionQuality: 1) else { return nil }
        return try? await repository.uploadImage(data)
    }

    /// The server's upload cap (`POST /uploads`, `collect(maxSize: "50mb")`).
    static let maxUploadBytes = 50 * 1024 * 1024

    /// Uploads all selected media in order. Throws if any item fails rather
    /// than skipping it. A skipped video meant the post published without it,
    /// silently. A video over the server's cap is refused before uploading.
    func uploadMedia(_ media: [PickedPostMedia]) async throws -> [String] {
        isUploadingMedia = true
        defer { isUploadingMedia = false }
        var urls: [String] = []
        for item in media {
            if let remote = item.remoteURL {
                urls.append(remote)
            } else if let image = item.image {
                guard let url = await uploadImage(image, original: item.sourceData) else { throw MediaUploadError.failed }
                urls.append(url)
            } else if let fileURL = item.videoURL {
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= Self.maxUploadBytes else { throw MediaUploadError.tooLarge }
                guard let url = try? await repository.uploadVideo(fileURL: fileURL) else { throw MediaUploadError.failed }
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - Submit

    /// Updates an existing post.
    func updatePost(
        postId: String,
        content: String,
        privacy: PostPrivacy,
        selectedMedia: [PickedPostMedia],
        existingImageUrls: [String],
        communityAudience: CommunityAudience? = nil,
        hashtags: [String],
        onSuccess: @escaping (Post) -> Void
    ) {
        let capturedPreview = linkPreview

        Task {
            isPosting = true
            defer { isPosting = false }

            // New media selected → replace all of it; none selected → keep the old media
            let imageUrls: [String]
            if !selectedMedia.isEmpty {
                do {
                    imageUrls = try await uploadMedia(selectedMedia)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            } else if capturedPreview != nil {
                // A link post's only picture is the link's thumbnail (sent below),
                // so a changed link must not keep the old link's picture.
                imageUrls = []
            } else {
                imageUrls = existingImageUrls
            }

            // Link post: the link's thumbnail still goes through image_url, as before
            let imageUrl = capturedPreview?.image

            let updatedPost = try? await repository.updatePost(
                postId: postId,
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                privacy: privacy,
                imageUrl: imageUrl,
                imageUrls: imageUrls,
                imageAlts: selectedMedia.isEmpty ? nil : selectedMedia.map(\.altText),
                linkUrl: capturedPreview?.url,
                articleTitle: capturedPreview?.title,
                communityAudience: communityAudience,
                hashtags: hashtags
            )
            if let post = updatedPost {
                onSuccess(post)
            }
        }
    }

    /// Posts immediately, without waiting on AI. Passes the newly created post (in full)
    /// to the caller via `onSuccess` so it can be inserted straight at the top of the
    /// feed, no need to wait for a separate reload to see your own post. After posting,
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
        publish: PublishChoice = .now,
        replacesDraft: String? = nil,
        onSuccess: @escaping (Post) -> Void
    ) {
        var finalContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let imageUrls: [String]
            do {
                imageUrls = selectedMedia.isEmpty ? [] : try await uploadMedia(selectedMedia)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            let imageUrl: String? = selectedMedia.isEmpty ? capturedPreview?.image : nil

            guard let post = try? await repository.createPost(
                content: finalContent.isEmpty ? " " : finalContent,
                mode: mode,
                privacy: privacy,
                imageUrl: imageUrl,
                imageUrls: imageUrls,
                imageAlts: selectedMedia.map(\.altText),
                linkUrl: capturedPreview?.url,
                articleTitle: capturedPreview?.title,
                hashtags: hashtags,
                publish: publish,
                replacesDraft: replacesDraft
            ) else {
                errorMessage = Bundle.app.loc(publish.isLive ? "Could not post. Please try again." : "Couldn't save the draft. Please try again.")
                return
            }
            let postId = post.id

            onSuccess(post)
            guard publish.isLive else { return }

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

/// Why a post's media couldn't be uploaded. Localized for the composer's alert.
enum MediaUploadError: LocalizedError {
    case tooLarge, failed

    var errorDescription: String? {
        switch self {
        case .tooLarge: return Bundle.app.loc("This video is too large to upload (max 50 MB).")
        case .failed:   return Bundle.app.loc("Couldn't upload one of your photos or videos. Please try again.")
        }
    }
}
