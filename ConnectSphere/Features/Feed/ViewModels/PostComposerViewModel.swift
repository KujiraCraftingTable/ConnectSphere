import Foundation
import Observation
import PhotosUI
import SwiftUI

/// Shared post-composer logic for text/poll/event posts — originally
/// Community-only (`CreateCommunityPostViewModel`), relocated here in Phase 2
/// so Feed's composer can reuse it too. `communityId` is now optional:
/// non-nil posts to a community (`/communities/:id/posts`), nil posts
/// straight to the Feed (`/posts`).
@Observable
class PostComposerViewModel {
    var postType: PostType = .text
    var content: String = ""
    var isPosting = false
    var errorMessage: String?
    let maxLength = 2000

    var pollOptions: [String] = ["", ""]
    var pollEndsAt: Date? = nil
    var showPollEndDate = false

    var eventTitle: String = ""
    var eventLocation: String = ""
    var eventStartsAt: Date = Date().addingTimeInterval(3600)
    var eventEndsAt: Date? = nil
    var showEventEndDate = false

    var jobTitle: String = ""
    var jobCompany: String = ""
    var jobLocation: String = ""
    var jobEmploymentType: EmploymentType? = nil
    var jobSalaryRange: String = ""
    var jobApplicationDeadline: Date? = nil
    var showJobApplicationDeadline = false

    // Media — text posts only, same field names/upload path Feed's
    // CreatePostView uses (backend only accepts image_urls on post_type='text').
    var selectedItems: [PhotosPickerItem] = []
    var selectedMedia: [PickedPostMedia] = []
    var isUploadingMedia = false

    // Link preview — auto-detected from typed content, mirrors
    // CreatePostViewModel.detectAndFetchLink so behavior matches Feed exactly.
    var isFetchingLink = false
    var linkPreview: LinkPreviewDTO? = nil
    private var linkPreviewTask: Task<Void, Never>? = nil

    private let client = NetworkClient.shared
    private let postRepository = PostRepository()
    /// Reused purely as a media loader/uploader utility (same multipart upload
    /// path as Feed's composer) — not exposed to any view, so its own
    /// Observable state never needs to be tracked here.
    private let mediaHelper = CreatePostViewModel()

    // MARK: - Validation

    var isValid: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch postType {
        case .text:
            // Parity with Feed: an image/video-only post (no caption) is valid too.
            return !trimmed.isEmpty || !selectedMedia.isEmpty || linkPreview != nil
        case .poll:
            guard !trimmed.isEmpty else { return false }
            let valid = pollOptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return valid.count >= 2
        case .event:
            guard !trimmed.isEmpty else { return false }
            return !eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && eventStartsAt > Date()
        case .job:
            guard !trimmed.isEmpty else { return false }
            return !jobTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var remaining: Int { maxLength - content.count }

    // MARK: - Submit

    /// `communityId` nil posts to the Feed (`POST /posts`), non-nil posts to a
    /// community (`POST /communities/:id/posts`). `mode`/`privacy` are always
    /// sent now — community posts ignore them server-side today (mode/privacy
    /// derive from the community), Feed posts need them to post with the
    /// composer's actual mode/privacy choice instead of a silent hobby/public
    /// default (see postModel.createCommunityPost's mode/privacy overrides).
    ///
    /// `hashtags` mirror Feed's `CreatePostViewModel.submitPost` — user-typed tags
    /// saved synchronously (`source = 'user'`). AI-generated tags are never surfaced
    /// on the client (`show_ai_tags` is always sent as `false`), so there is nothing
    /// to refetch after the post is created.
    func submitPost(
        communityId: String?,
        token: String,
        mode: AppMode,
        privacy: PostPrivacy,
        hashtags: [String] = [],
        onSuccess: @escaping (CommunityPost) -> Void
    ) async {
        guard isValid else { return }
        isPosting = true
        errorMessage = nil
        do {
            let post: CommunityPost
            switch postType {
            case .text:  post = try await submitText(communityId: communityId, token: token, mode: mode, privacy: privacy, hashtags: hashtags)
            case .poll:  post = try await submitPoll(communityId: communityId, token: token, mode: mode, privacy: privacy, hashtags: hashtags)
            case .event: post = try await submitEvent(communityId: communityId, token: token, mode: mode, privacy: privacy, hashtags: hashtags)
            case .job:   post = try await submitJob(communityId: communityId, token: token, mode: mode, privacy: privacy, hashtags: hashtags)
            }
            content = ""
            selectedItems = []
            selectedMedia = []
            linkPreview = nil
            onSuccess(post)
        } catch {
            if case APIError.serverError(_, let msg) = error { errorMessage = msg }
            else if let upload = error as? MediaUploadError { errorMessage = upload.errorDescription }
            else { errorMessage = Bundle.app.loc("Could not post. Please try again.") }
        }
        isPosting = false
    }

    // MARK: - Media

    /// Image → decode to UIImage; video → copy to a temp file + generate a thumbnail — the
    /// same logic Feed's composer uses (delegated through mediaHelper, not duplicated).
    func loadSelectedMedia(_ items: [PhotosPickerItem]) async {
        selectedMedia = await mediaHelper.loadSelectedMedia(items)
    }

    /// Uploads all selected media through the same multipart route Feed uses
    /// (POST /uploads), in order. Throws `MediaUploadError` if any item fails.
    private func uploadSelectedMedia() async throws -> [String] {
        guard !selectedMedia.isEmpty else { return [] }
        isUploadingMedia = true
        defer { isUploadingMedia = false }
        return try await mediaHelper.uploadMedia(selectedMedia)
    }

    // MARK: - Link preview (debounced)

    /// Detects a URL in the content being typed and fetches a link preview 800ms after
    /// typing stops — mirrors CreatePostViewModel.detectAndFetchLink (Feed) 1:1 but
    /// uses PostRepository directly since it doesn't need Feed's VM's own state.
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
            linkPreview = try? await postRepository.fetchLinkPreview(url: urlString)
            isFetchingLink = false
        }
    }

    // MARK: - Private helpers

    private func postPath(communityId: String?) -> String {
        communityId.map { "/communities/\($0)/posts" } ?? "/posts"
    }

    private func submitText(communityId: String?, token: String, mode: AppMode, privacy: PostPrivacy, hashtags: [String]) async throws -> CommunityPost {
        var finalContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedPreview = linkPreview

        // Strip the detected URL out of the content — the link already shows via its
        // own card, leaving it in the text would duplicate it (same as Feed's submitPost).
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

        let imageUrls = try await uploadSelectedMedia()

        var dict: [String: Any] = [
            "content":      finalContent,
            "post_type":    "text",
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
            "show_ai_tags": false,
        ]
        if !imageUrls.isEmpty                   { dict["image_urls"]    = imageUrls }
        if let url = capturedPreview?.url       { dict["link_url"]      = url }
        if let title = capturedPreview?.title   { dict["article_title"] = title }
        if !hashtags.isEmpty                    { dict["hashtags"]      = hashtags }

        let body = try? JSONSerialization.data(withJSONObject: dict)
        let res = try await client.fetch(DataResponse<CommunityPostDTO>.self,
                                          path: postPath(communityId: communityId),
                                          method: "POST", token: token, bodyData: body)
        return res.data.toCommunityPost()
    }

    private func submitPoll(communityId: String?, token: String, mode: AppMode, privacy: PostPrivacy, hashtags: [String]) async throws -> CommunityPost {
        let validOptions = pollOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var dict: [String: Any] = [
            "content":      content.trimmingCharacters(in: .whitespacesAndNewlines),
            "post_type":    "poll",
            "options":      validOptions,
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
            "show_ai_tags": false,
        ]
        if showPollEndDate, let endsAt = pollEndsAt {
            dict["endsAt"] = ISO8601DateFormatter().string(from: endsAt)
        }
        if !hashtags.isEmpty { dict["hashtags"] = hashtags }
        let body = try? JSONSerialization.data(withJSONObject: dict)
        let res = try await client.fetch(DataResponse<CommunityPostDTO>.self,
                                          path: postPath(communityId: communityId),
                                          method: "POST", token: token, bodyData: body)
        return res.data.toCommunityPost()
    }

    private func submitEvent(communityId: String?, token: String, mode: AppMode, privacy: PostPrivacy, hashtags: [String]) async throws -> CommunityPost {
        let iso = ISO8601DateFormatter()
        var eventDict: [String: Any] = [
            "title":    eventTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            "location": eventLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            "startsAt": iso.string(from: eventStartsAt),
        ]
        if showEventEndDate, let endsAt = eventEndsAt { eventDict["endsAt"] = iso.string(from: endsAt) }

        var dict: [String: Any] = [
            "content":      content.trimmingCharacters(in: .whitespacesAndNewlines),
            "post_type":    "event",
            "eventData":    eventDict,
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
            "show_ai_tags": false,
        ]
        if !hashtags.isEmpty { dict["hashtags"] = hashtags }
        let body = try? JSONSerialization.data(withJSONObject: dict)
        let res = try await client.fetch(DataResponse<CommunityPostDTO>.self,
                                          path: postPath(communityId: communityId),
                                          method: "POST", token: token, bodyData: body)
        return res.data.toCommunityPost()
    }

    private func submitJob(communityId: String?, token: String, mode: AppMode, privacy: PostPrivacy, hashtags: [String]) async throws -> CommunityPost {
        var jobDict: [String: Any] = [
            "title": jobTitle.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        let company = jobCompany.trimmingCharacters(in: .whitespacesAndNewlines)
        if !company.isEmpty { jobDict["company"] = company }
        let location = jobLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty { jobDict["location"] = location }
        if let jobEmploymentType { jobDict["employmentType"] = jobEmploymentType.rawValue }
        let salaryRange = jobSalaryRange.trimmingCharacters(in: .whitespacesAndNewlines)
        if !salaryRange.isEmpty { jobDict["salaryRange"] = salaryRange }
        if showJobApplicationDeadline, let deadline = jobApplicationDeadline {
            // Date-only (no time component) to match the backend's DATE column.
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = TimeZone(identifier: "UTC")
            jobDict["applicationDeadline"] = df.string(from: deadline)
        }

        var dict: [String: Any] = [
            "content":      content.trimmingCharacters(in: .whitespacesAndNewlines),
            "post_type":    "job",
            "jobData":      jobDict,
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
            "show_ai_tags": false,
        ]
        if !hashtags.isEmpty { dict["hashtags"] = hashtags }
        let body = try? JSONSerialization.data(withJSONObject: dict)
        let res = try await client.fetch(DataResponse<CommunityPostDTO>.self,
                                          path: postPath(communityId: communityId),
                                          method: "POST", token: token, bodyData: body)
        return res.data.toCommunityPost()
    }
}
