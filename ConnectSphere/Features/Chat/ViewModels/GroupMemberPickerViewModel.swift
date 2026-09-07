import Foundation
import Observation

/// Backs `GroupMemberPickerView` — loads the current user's accepted
/// connections (same data source `ConnectionsListView` uses) and tracks a
/// multi-select `Set<String>` of chosen user ids, capped at the number of
/// remaining slots under the group's 100-member limit.
@MainActor
@Observable
class GroupMemberPickerViewModel {
    var connections: [ConnectionItemDTO] = []
    var isLoading = false
    var error: String?
    var selectedIds: Set<String> = []

    private let repository = ConnectionRepository()

    /// Load accepted connections for the given mode, excluding anyone already
    /// in the group (empty set when picking for a brand-new group).
    func load(mode: String, excluding excludedIds: Set<String>) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await repository.fetchConnections(mode: mode, status: "accepted")
            connections = all.filter { !excludedIds.contains($0.user.id) }
        } catch {
            self.error = Bundle.app.loc("Could not load connections")
        }
    }

    /// Toggle a user's selection, refusing to add past `cap` (remaining slots
    /// under the 100-member hard cap).
    func toggle(_ userId: String, cap: Int) {
        if selectedIds.contains(userId) {
            selectedIds.remove(userId)
        } else if selectedIds.count < cap {
            selectedIds.insert(userId)
        }
    }
}
