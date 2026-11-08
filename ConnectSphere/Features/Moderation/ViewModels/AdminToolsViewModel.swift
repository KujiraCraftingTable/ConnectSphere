import Foundation
import Observation

/// The official account's admin tools: overall counts and looking up one
/// account by username.
@MainActor
@Observable
final class AdminToolsViewModel {
    private(set) var stats: AdminStats?
    private(set) var statsError: String?
    var query = ""
    private(set) var found: AdminUserLookup?
    private(set) var lookupError: String?
    private(set) var isLookingUp = false

    private let repository = ModerationRepository()

    var canLookUp: Bool { !trimmedQuery.isEmpty && !isLookingUp }
    private var trimmedQuery: String {
        query.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
    }

    func loadStats() async {
        statsError = nil
        do { stats = try await repository.adminStats() } catch { statsError = friendlyError(error) }
    }

    func lookUp() async {
        guard canLookUp else { return }
        isLookingUp = true
        lookupError = nil
        found = nil
        defer { isLookingUp = false }
        do { found = try await repository.lookupUser(trimmedQuery) } catch { lookupError = friendlyError(error) }
    }
}
