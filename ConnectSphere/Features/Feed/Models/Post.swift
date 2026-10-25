import Foundation

extension Notification.Name {
    static let postDeleted = Notification.Name("postDeleted")
    static let postUpdated = Notification.Name("postUpdated")
    /// A soft-deleted post was restored (Undo toast or Recently Deleted screen).
    /// userInfo["post"] carries the restored `Post`. Deliberately separate from
    /// `.postUpdated` — that notification's observers only patch an EXISTING
    /// list entry (`FeedViewModel.updatePost`/`ProfileViewModel.updatePost`
    /// both use `firstIndex(where:)` with no insert fallback), but a restored
    /// post was just removed from those lists and needs to be re-inserted.
    static let postRestored = Notification.Name("postRestored")
    /// A new post was successfully created, from ANY composer entry point
    /// (Feed's, Profile's own, etc.). userInfo["post"] carries the created
    /// `Post`. Feed/Community view models already learn about their own new
    /// post directly via the composer's success callback (no round-trip
    /// needed), but `AppState.currentUser.postCount` and a `ProfileViewModel`
    /// that ISN'T the one that created the post (e.g. still alive in memory
    /// after switching tabs from Home, where post creation happens) have no
    /// other way to learn the count went up — this closes that gap.
    static let postCreated = Notification.Name("postCreated")
}

enum PostPrivacy: String, CaseIterable {
    case publicAll  = "public"
    case friends    = "friends"
    case onlyMe     = "only_me"

    var label: String {
        switch self {
        case .publicAll: return Bundle.app.loc("Public")
        case .friends:   return Bundle.app.loc("Friends")
        case .onlyMe:    return Bundle.app.loc("Only me")
        }
    }

    var icon: String {
        switch self {
        case .publicAll: return "globe"
        case .friends:   return "person.2.fill"
        case .onlyMe:    return "lock.fill"
        }
    }

    var description: String {
        switch self {
        case .publicAll: return Bundle.app.loc("Everyone can see")
        case .friends:   return Bundle.app.loc("Only your friends")
        case .onlyMe:    return Bundle.app.loc("Only you can see")
        }
    }

    /// Mode-dependent label: the "friends" level is called "Friends" in hobby
    /// mode, "Connections" in work mode. Other levels are unchanged.
    func label(for mode: AppMode) -> String {
        if self == .friends {
            return mode == .hobby ? Bundle.app.loc("Friends") : Bundle.app.loc("Connections")
        }
        return label
    }

    /// Mode-dependent description, kept in sync with the "friends"/"connections" wording.
    func description(for mode: AppMode) -> String {
        if self == .friends {
            return mode == .hobby
                ? Bundle.app.loc("Only your friends")
                : Bundle.app.loc("Only your connections")
        }
        return description
    }
}

/// Condensed version of the original post embedded in a shared post
struct SharedPostPreview {
    let id: String
    let author: UserProfile
    let content: String
    let imageUrl: String?
    var imageUrls: [String] = []
    /// Alt text per `imageUrls` entry ('' = none).
    var imageAlts: [String] = []
    /// The text's language (en / vi / other / none) and its translation into
    /// the other of en/vi, made on the server when it was published.
    var contentLang: String? = nil
    var translatedContent: String? = nil
    let linkUrl: String?
    let articleTitle: String?
    let timestamp: Date

    /// Images to render the grid: prefer the new array, fall back to the old post's single image
    /// Alt text lined up with `displayImageUrls` (the legacy single image has none).
    var displayImageAlts: [String] { imageUrls.isEmpty ? [] : imageAlts }

    var displayImageUrls: [String] {
        if !imageUrls.isEmpty { return imageUrls }
        if linkUrl == nil, let imageUrl { return [imageUrl] }
        return []
    }
}

struct Post: Identifiable {
    let id: String
    let author: UserProfile
    let content: String
    let timestamp: Date
    let mode: AppMode
    var privacy: PostPrivacy = .publicAll
    var linkUrl: String?         // original URL for the link preview
    var imageUrl: String?        // thumbnail URL (from link preview or upload) — legacy, = first image
    var imageUrls: [String] = [] // uploaded image array, ordered
    /// Alt text per `imageUrls` entry ('' = none).
    var imageAlts: [String] = []
    /// The text's language (en / vi / other / none) and its translation into
    /// the other of en/vi, made on the server when it was published.
    var contentLang: String? = nil
    var translatedContent: String? = nil
    var likeCount: Int
    var commentCount: Int
    var shareCount: Int
    var isLiked: Bool = false
    var isSaved: Bool = false
    var articleTitle: String?
    var tags: [String]
    /// non-nil = this is a shared post; sharedPost is nil when the original post has been deleted
    var sharedPostId: String? = nil
    var sharedPost: SharedPostPreview? = nil
    /// A community shared to the feed: its card under the note.
    var sharedCommunity: SharedCommunityRef? = nil
    /// Poll/event posts on the Feed reuse the same community-agnostic
    /// PostType/PollData/EventData types from Communities (see
    /// CommunityPost.swift) — a Feed post and a community post render polls
    /// and events identically, just via a different card entry point.
    var postType: PostType = .text
    var pollData: PollData? = nil
    var eventData: EventData? = nil
    var jobData: JobData? = nil
    /// Set only for a post from a community the viewer's feed surfaces —
    /// drives PostCard's combined "community avatar/name + actual poster"
    /// header instead of the normal single-author one.
    var isPinned: Bool = false
    var pinnedAt: Date? = nil
    var community: CommunityRef? = nil
    /// Only on your own unpublished posts: "draft", "scheduled", or in a
    /// community that approves posts "pending" / "declined".
    var publishStatus: String? = nil
    /// When a scheduled post goes out.
    var publishAt: Date? = nil
    /// Why a community moderator declined it.
    var declineReason: String? = nil

    /// Images to render the grid: prefer the new array, fall back to the old post's single image.
    /// Posts with a link preview don't count (that image belongs to the link card).
    /// Alt text lined up with `displayImageUrls` (the legacy single image has none).
    var displayImageAlts: [String] { imageUrls.isEmpty ? [] : imageAlts }

    var displayImageUrls: [String] {
        if !imageUrls.isEmpty { return imageUrls }
        if linkUrl == nil, let imageUrl { return [imageUrl] }
        return []
    }
}
