import Foundation
import Observation

/// A person's followers or the people they follow, in one mode. Friends are
/// excluded (they're in the Friends list) — the same people the counts count.
@MainActor
@Observable
final class FollowListViewModel {
    let userId: String
    let showsFollowers: Bool
    private(set) var people: [ConnectionUserDTO] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let repository = ConnectionRepository()

    init(userId: String, showsFollowers: Bool) {
        self.userId = userId
        self.showsFollowers = showsFollowers
    }

    func load(mode: AppMode) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            people = try await repository.fetchFollows(userId: userId, followers: showsFollowers, mode: mode.rawValue)
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}
