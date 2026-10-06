import Foundation
import Observation

/// Users the current user has blocked, and unblocking them.
@MainActor
@Observable
final class BlockedUsersViewModel {
    private(set) var blockedUsers: [BlockedUserDTO] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Rows with an unblock in flight (spinner + disabled button).
    private(set) var unblockingIds: Set<String> = []

    private let repository = UserRepository()

    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            blockedUsers = try await repository.fetchBlockedUsers()
        } catch {
            loadError = friendlyError(error)
        }
    }

    /// On failure the row stays, so the user can simply try again.
    func unblock(_ user: BlockedUserDTO) async {
        unblockingIds.insert(user.id)
        defer { unblockingIds.remove(user.id) }
        guard (try? await repository.unblockUser(userId: user.id)) != nil else { return }
        blockedUsers.removeAll { $0.id == user.id }
    }
}
