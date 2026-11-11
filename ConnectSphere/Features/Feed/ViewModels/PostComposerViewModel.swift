import Foundation
import Observation
import PhotosUI
import SwiftUI

/// Shared post-composer logic for text/poll/event posts. Originally
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
    var jobLocation: String = ""
    var jobEmploymentType: EmploymentType? = nil
    var jobSalaryRange: String = ""
    var jobApplicationDeadline: Date? = nil
    var showJobApplicationDeadline = false
    /// The job on your company's careers page, so applicants can check it's
    /// real. Required; the company itself is your verified HR company.
    var jobCareersUrl: String = ""
    /// The company's job description PDF, once uploaded (`/uploads/jd/…`).
    private(set) var jobJDPath: String?
    private(set) var jobJDName: String?
    private(set) var isUploadingJD = false
    static let jdLimit = 10 * 1024 * 1024
    var jobWorkFormat: String? = nil
    /// Where the job is (on-site / hybrid), for "Near you" by ward distance.
    var jobProvinceCode: String? = nil
    var jobWardId: String? = nil
    var jobLevel: String? = nil
    /// VND million / month, as typed.
    var jobSalaryMin = ""
    var jobSalaryMax = ""
    /// Pay is "Negotiable": the range is hidden and not sent.
    var jobSalaryNegotiable = false
    /// Required skills, picked from the skill catalogue (SkillPickerView).
    var jobSkills: [String] = []

    /// Both empty, or numbers with min ≤ max.
    var jobSalaryValid: Bool {
        if jobSalaryNegotiable { return true }
        let lo = Int(jobSalaryMin), hi = Int(jobSalaryMax)
        if !jobSalaryMin.isEmpty && lo == nil { return false }
        if !jobSalaryMax.isEmpty && hi == nil { return false }
        if let lo, let hi { return lo <= hi }
        return true
    }

    // Media, text posts only, same field names/upload path Feed's
    // CreatePostView uses (backend only accepts image_urls on post_type='text').
    /// Post now (default) or save as a draft.
    var publish: PublishChoice = .now
    /// The draft this post was opened from: saving or posting replaces it.
    var replacesDraftId: String?
    private var skipNextLinkDetect = false

    var selectedItems: [PhotosPickerItem] = []
    var selectedMedia: [PickedPostMedia] = []
    var isUploadingMedia = false

    // Link preview, auto-detected from typed content, mirrors
    // CreatePostViewModel.detectAndFetchLink so behavior matches Feed exactly.
    var isFetchingLink = false
    var linkPreview: LinkPreviewDTO? = nil
    private var linkPreviewTask: Task<Void, Never>? = nil

    private let client = NetworkClient.shared
    private let postRepository = PostRepository()
    /// Reused purely as a media loader/uploader utility (same multipart upload
    /// path as Feed's composer), not exposed to any view, so its own
    /// Observable state never needs to be tracked here.
    private let mediaHelper = CreatePostViewModel()

    // MARK: - Validation

    var isValid: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch postType {
        case .text:
            // Parity with Feed: an image/video-only post (no caption) is valid
            // too, once every picked item has loaded, or it'd be left out.
            return (!trimmed.isEmpty || !selectedMedia.isEmpty || linkPreview != nil) && pendingMediaCount == 0
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
                && !jobCareersUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && jobSalaryValid && jobSkills.count <= 10
                && (jobWorkFormat == "remote" || jobWardId != nil)
        case .listing:
            // Listings are made in the Marketplace (CreateListingView), not here.
            return false
        }
    }

    var remaining: Int { maxLength - content.count }

    /// Community posts only: who can see it. Members only unless the poster
    /// picks Public (not offered in a private community).
    var communityAudience: CommunityAudience = .members

    // MARK: - Submit

    /// `communityId` nil posts to the Feed (`POST /posts`), non-nil posts to a
    /// community (`POST /communities/:id/posts`). `mode`/`privacy` are always
    /// sent now, community posts ignore them server-side today (mode/privacy
    /// derive from the community), Feed posts need them to post with the
    /// composer's actual mode/privacy choice instead of a silent hobby/public
    /// default (see postModel.createCommunityPost's mode/privacy overrides).
    ///
    /// `hashtags` mirror Feed's `CreatePostViewModel.submitPost`, user-typed tags
    /// saved synchronously (`source = 'user'`). AI-generated tags are never shown
    /// (they only feed AI search), so there is nothing to refetch after the post
    /// is created.
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
            case .listing:
                throw APIError.serverError(statusCode: 400, message: Bundle.app.loc("Listings are created from the Marketplace"))
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

    /// Image → decode to UIImage; video → copy to a temp file + generate a thumbnail. The
    /// same logic Feed's composer uses (delegated through mediaHelper, not duplicated).
    func loadSelectedMedia(_ items: [PhotosPickerItem]) async {
        selectedMedia = await mediaHelper.loadSelectedMedia(items, keeping: selectedMedia) { [weak self] soFar in
            self?.selectedMedia = soFar
        }
    }

    /// Picked items still loading (one blinking tile each).
    var pendingMediaCount: Int { mediaHelper.pendingMediaCount }

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
    /// typing stops, mirrors CreatePostViewModel.detectAndFetchLink (Feed) 1:1 but
    /// uses PostRepository directly since it doesn't need Feed's VM's own state.
    func detectAndFetchLink(_ text: String) {
        // A loaded draft's text has its URL stripped (the link lives in its
        // card), so detecting on it would wrongly drop the card.
        if skipNextLinkDetect { skipNextLinkDetect = false; return }
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

    // MARK: - Drafts

    /// Fills the composer from a saved draft (any post type).
    func load(_ draft: Post) {
        replacesDraftId = draft.id
        postType = draft.postType
        skipNextLinkDetect = draft.linkUrl != nil && draft.content != content
        content = draft.content
        selectedItems = []
        selectedMedia = PickedPostMedia.remote(draft.imageUrls, alts: draft.imageAlts)
        linkPreview = draft.linkUrl.map {
            LinkPreviewDTO(url: $0, title: draft.articleTitle ?? $0, description: nil, image: draft.imageUrl, siteName: nil)
        }
        if let poll = draft.pollData {
            let texts = poll.options.sorted { $0.position < $1.position }.map(\.text)
            pollOptions = texts.count >= 2 ? texts : texts + Array(repeating: "", count: 2 - texts.count)
            pollEndsAt = poll.options.first?.endsAt
            showPollEndDate = pollEndsAt != nil
        }
        if let event = draft.eventData {
            eventTitle = event.title
            eventLocation = event.location ?? ""
            eventStartsAt = event.startsAt
            eventEndsAt = event.endsAt
            showEventEndDate = event.endsAt != nil
        }
        if let job = draft.jobData {
            jobTitle = job.title
            jobCareersUrl = job.careersUrl ?? ""
            jobJDPath = job.jdPath
            jobJDName = job.jdPath == nil ? nil : Bundle.app.loc("Job description (PDF)")
            jobLocation = job.location ?? ""
            jobEmploymentType = job.employmentType
            jobSalaryRange = job.salaryRange ?? ""
            jobSalaryNegotiable = job.salaryNegotiable
            jobApplicationDeadline = job.applicationDeadline
            showJobApplicationDeadline = job.applicationDeadline != nil
        }
    }

    // MARK: - Job description PDF

    /// Uploads the picked PDF (from the file importer) as this job's description.
    func attachJD(at url: URL, token: String) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = Bundle.app.loc("Couldn't read that file.")
            return
        }
        guard data.count <= Self.jdLimit else {
            errorMessage = Bundle.app.loc("The job description must be 10 MB or smaller.")
            return
        }
        isUploadingJD = true
        defer { isUploadingJD = false }
        do {
            jobJDPath = try await HRRepository().uploadJD(data, fileName: url.lastPathComponent, token: token)
            jobJDName = url.lastPathComponent
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func removeJD() {
        jobJDPath = nil
        jobJDName = nil
    }

    // MARK: - Private helpers

    private func postPath(communityId: String?) -> String {
        communityId.map { "/communities/\($0)/posts" } ?? "/posts"
    }

    private func submitText(communityId: String?, token: String, mode: AppMode, privacy: PostPrivacy, hashtags: [String]) async throws -> CommunityPost {
        var finalContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedPreview = linkPreview

        // Strip the detected URL out of the content. The link already shows via its
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
            "content_format": PostRepository.contentFormat,
            "post_type":    "text",
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
        ]
        if !imageUrls.isEmpty                   { dict["image_urls"]    = imageUrls }
        if selectedMedia.contains(where: { !$0.altText.isEmpty }) { dict["image_alts"] = selectedMedia.map(\.altText) }
        if let url = capturedPreview?.url       { dict["link_url"]      = url }
        if let title = capturedPreview?.title   { dict["article_title"] = title }
        if !hashtags.isEmpty                    { dict["hashtags"]      = hashtags }
        publish.apply(to: &dict, replacing: replacesDraftId)
        if communityId != nil { dict["community_audience"] = communityAudience.rawValue }

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
            "content_format": PostRepository.contentFormat,
            "post_type":    "poll",
            "options":      validOptions,
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
        ]
        if showPollEndDate, let endsAt = pollEndsAt {
            dict["endsAt"] = ISO8601DateFormatter().string(from: endsAt)
        }
        if !hashtags.isEmpty { dict["hashtags"] = hashtags }
        publish.apply(to: &dict, replacing: replacesDraftId)
        if communityId != nil { dict["community_audience"] = communityAudience.rawValue }
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
            "content_format": PostRepository.contentFormat,
            "post_type":    "event",
            "eventData":    eventDict,
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
        ]
        if !hashtags.isEmpty { dict["hashtags"] = hashtags }
        publish.apply(to: &dict, replacing: replacesDraftId)
        if communityId != nil { dict["community_audience"] = communityAudience.rawValue }
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
        jobDict["careersUrl"] = jobCareersUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jobJDPath { jobDict["jdPath"] = jobJDPath }
        let location = jobLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty { jobDict["location"] = location }
        if let jobEmploymentType { jobDict["employmentType"] = jobEmploymentType.rawValue }
        let salaryRange = jobSalaryRange.trimmingCharacters(in: .whitespacesAndNewlines)
        if !salaryRange.isEmpty { jobDict["salaryRange"] = salaryRange }
        if let jobWorkFormat { jobDict["workFormat"] = jobWorkFormat }
        // A remote job has no place; the ward picker is hidden for it.
        if jobWorkFormat != "remote", let jobWardId { jobDict["wardId"] = jobWardId }
        if let jobLevel { jobDict["level"] = jobLevel }
        if jobSalaryNegotiable {
            jobDict["salaryNegotiable"] = true
        } else {
            if let lo = Int(jobSalaryMin) { jobDict["salaryMin"] = lo }
            if let hi = Int(jobSalaryMax) { jobDict["salaryMax"] = hi }
        }
        if !jobSkills.isEmpty { jobDict["skills"] = jobSkills }
        if showJobApplicationDeadline, let deadline = jobApplicationDeadline {
            // Date-only (no time component) to match the backend's DATE column.
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = TimeZone(identifier: "UTC")
            jobDict["applicationDeadline"] = df.string(from: deadline)
        }

        var dict: [String: Any] = [
            "content":      content.trimmingCharacters(in: .whitespacesAndNewlines),
            "content_format": PostRepository.contentFormat,
            "post_type":    "job",
            "jobData":      jobDict,
            "mode":         mode.rawValue,
            "privacy":      privacy.rawValue,
        ]
        if !hashtags.isEmpty { dict["hashtags"] = hashtags }
        publish.apply(to: &dict, replacing: replacesDraftId)
        if communityId != nil { dict["community_audience"] = communityAudience.rawValue }
        let body = try? JSONSerialization.data(withJSONObject: dict)
        let res = try await client.fetch(DataResponse<CommunityPostDTO>.self,
                                          path: postPath(communityId: communityId),
                                          method: "POST", token: token, bodyData: body)
        return res.data.toCommunityPost()
    }
}
