import Foundation
import PhotosUI
import SwiftUI
import UserNotifications

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

    func loadSelectedMedia(_ items: [PhotosPickerItem]) async -> [UIImage] {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        return images
    }

    func uploadImage(_ image: UIImage) async -> String? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        return try? await repository.uploadImage(data)
    }

    /// Upload lần lượt toàn bộ ảnh đã chọn; ảnh lỗi bị bỏ qua, giữ đúng thứ tự
    func uploadImages(_ images: [UIImage]) async -> [String] {
        isUploadingMedia = true
        defer { isUploadingMedia = false }
        var urls: [String] = []
        for image in images {
            if let url = await uploadImage(image) { urls.append(url) }
        }
        return urls
    }

    // MARK: - Submit

    /// Cập nhật bài viết đã có.
    func updatePost(
        postId: String,
        content: String,
        privacy: PostPrivacy,
        selectedImages: [UIImage],
        existingImageUrls: [String],
        onSuccess: @escaping (Post) -> Void
    ) {
        let capturedPreview = linkPreview

        Task {
            isPosting = true
            defer { isPosting = false }

            // Chọn ảnh mới → thay toàn bộ; không chọn → giữ ảnh cũ
            let imageUrls: [String]
            if !selectedImages.isEmpty {
                imageUrls = await uploadImages(selectedImages)
            } else {
                imageUrls = existingImageUrls
            }

            // Link post: thumbnail của link đi qua image_url như cũ
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

    /// Post bài ngay lập tức, không chờ AI. Sau khi đăng xong, background task
    /// sẽ đợi 10 giây rồi kiểm tra xem backend có tạo notification mode mismatch không.
    func submitPost(
        content: String,
        mode: AppMode,
        privacy: PostPrivacy,
        authToken: String?,
        selectedImages: [UIImage],
        onSuccess: @escaping () -> Void
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

        guard !finalContent.isEmpty || capturedPreview != nil || !selectedImages.isEmpty else { return }

        Task {
            isPosting = true
            defer { isPosting = false }

            // Upload TOÀN BỘ ảnh đã chọn (trước đây chỉ ảnh đầu tiên);
            // link post không kèm ảnh thì thumbnail của link đi qua image_url
            let imageUrls = selectedImages.isEmpty ? [] : await uploadImages(selectedImages)
            let imageUrl: String? = selectedImages.isEmpty ? capturedPreview?.image : nil

            guard let postId = try? await repository.createPost(
                content: finalContent.isEmpty ? " " : finalContent,
                mode: mode,
                privacy: privacy,
                imageUrl: imageUrl,
                imageUrls: imageUrls,
                linkUrl: capturedPreview?.url,
                articleTitle: capturedPreview?.title
            ) else {
                return
            }

            onSuccess()

            // Background: check mismatch notification sau 10 giây
            if let token = authToken {
                Task.detached(priority: .background) {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    await self.checkAndNotifyMismatch(postId: postId, token: token)
                }
            }
        }
    }

    // MARK: - Private

    /// Fetch notification từ backend; nếu có mismatch thì hiện iOS local notification banner.
    private func checkAndNotifyMismatch(postId: String, token: String) async {
        guard let notif = try? await notifRepository.fetchMismatchFor(postId: postId, token: token) else { return }

        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

        let content = UNMutableNotificationContent()
        content.title = "Gợi ý từ AI"
        let modeName = notif.payload.suggestedMode == "friend" ? "Bạn bè" : "Đồng nghiệp"
        content.body = notif.payload.reason ?? "Bài viết này có thể phù hợp hơn với chế độ \(modeName)"
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
