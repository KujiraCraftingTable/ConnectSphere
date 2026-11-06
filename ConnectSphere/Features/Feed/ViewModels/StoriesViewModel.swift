import Foundation
import Observation

/// The stories row: your own story plus connections' stories from the last
/// 24 h, in the current mode.
@MainActor
@Observable
final class StoriesViewModel {
    private(set) var groups: [StoryGroup] = []
    /// This mode's persona, "Your story" shows its avatar, not the session
    /// user's unscoped one.
    private(set) var myProfile: UserProfile?

    private let storyRepository = StoryRepository()
    private let profileRepository = ProfileRepository()

    func myGroup(currentUserId: String?) -> StoryGroup? {
        groups.first { $0.author.id == currentUserId }
    }

    /// Unseen-first: an author with any unseen story sorts before one whose
    /// stories were all viewed. `sorted` is stable, so within each bucket the
    /// server's order is kept.
    func otherGroups(currentUserId: String?) -> [StoryGroup] {
        groups.filter { $0.author.id != currentUserId }
            .sorted { $0.hasUnseen && !$1.hasUnseen }
    }

    /// Stories and the persona are both fetched per mode: story authors come
    /// back mode-scoped, and the persona mirrors ProfileView's per-mode fetch.
    func load(mode: AppMode, currentUserId: String?) async {
        async let storiesResult: [StoryDTO]? = try? storyRepository.fetchStories(mode: mode.rawValue)
        async let profileResult: UserProfile? = {
            guard let currentUserId else { return nil }
            return try? await profileRepository.fetchUser(userId: currentUserId, mode: mode.rawValue)
        }()
        let (stories, profile) = await (storiesResult, profileResult)
        if let stories { groups = groupStories(stories) }
        if let profile { myProfile = profile }
    }
}
