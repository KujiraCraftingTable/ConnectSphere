import Foundation
import Observation

/// Loads a community shared into a chat, as the viewer.
@MainActor
@Observable
final class ChatCommunityCardViewModel {
    private(set) var community: SharedCommunityRef?
    private(set) var unavailable = false
    private let repository = CommunityRepository()

    func load(communityId: String, token: String) async {
        guard community == nil else { return }
        do {
            let c = try await repository.fetchDetail(communityId: communityId, token: token)
            community = SharedCommunityRef(id: c.id, name: c.name, coverUrl: c.coverUrl, coverColor: c.coverColor,
                                           iconEmoji: c.iconEmoji, memberCount: c.memberCount, privacy: c.privacy.rawValue)
        } catch {
            unavailable = true
        }
    }
}
