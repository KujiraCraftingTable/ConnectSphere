import Foundation
import Observation

/// "..." › Manage roles (admin only): find members by name and make them
/// moderator, member or the admin.
@MainActor
@Observable
final class ManageRolesViewModel {
    var query = ""
    private(set) var results: [CommunityMember] = []
    private(set) var isSearching = false
    private(set) var banned: [BannedMember] = []
    var errorMessage: String?

    private let communityId: String
    private let repository = CommunityRepository()
    private var searchTask: Task<Void, Never>?

    init(communityId: String) { self.communityId = communityId }

    // MARK: - Search
    /// Waits for typing to pause so each keystroke doesn't hit the server.
    func queryChanged(token: String) {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(token: token)
        }
    }

    func search(token: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await repository.fetchMembers(communityId: communityId, search: text, limit: 50, token: token)
            guard text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            results = found
        } catch where !error.isCancellation {
            errorMessage = friendlyError(error)
        } catch {}
    }

    // MARK: - Bans
    func loadBans(token: String) async {
        do {
            banned = try await repository.fetchBans(communityId: communityId, token: token)
        } catch where !error.isCancellation {
            errorMessage = friendlyError(error)
        } catch {}
    }

    /// Removed from the community and kept out.
    func ban(_ member: CommunityMember, token: String) async {
        do {
            try await repository.banMember(communityId: communityId, userId: member.id, token: token)
            results.removeAll { $0.id == member.id }
            await loadBans(token: token)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func unban(_ person: BannedMember, token: String) async {
        do {
            try await repository.unbanMember(communityId: communityId, userId: person.id, token: token)
            banned.removeAll { $0.id == person.id }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Roles
    /// Moderator or member.
    func setRole(_ member: CommunityMember, to role: MemberRole, token: String) async {
        do {
            try await repository.updateMemberRole(communityId: communityId, userId: member.id, role: role, token: token)
            replace(member.id, role)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// True once `member` is the admin and the viewer has stepped down.
    func makeAdmin(_ member: CommunityMember, token: String) async -> Bool {
        do {
            try await repository.transferAdmin(communityId: communityId, userId: member.id, token: token)
            NotificationCenter.default.post(name: .communitiesChanged, object: nil)
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }

    private func replace(_ userId: String, _ role: MemberRole) {
        guard let i = results.firstIndex(where: { $0.id == userId }) else { return }
        let m = results[i]
        results[i] = CommunityMember(
            id: m.id, username: m.username, displayName: m.displayName,
            avatarColor: m.avatarColor, jobTitle: m.jobTitle, company: m.company,
            role: role, joinedAt: m.joinedAt, avatarUrl: m.avatarUrl, isFriend: m.isFriend)
    }
}
