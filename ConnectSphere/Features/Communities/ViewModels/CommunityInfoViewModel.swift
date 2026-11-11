import Foundation
import Observation

/// The "About this community" page.
@MainActor
@Observable
final class CommunityInfoViewModel {
    private(set) var info: CommunityInfo?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let communityId: String
    private let repository = CommunityRepository()

    init(communityId: String) { self.communityId = communityId }

    func load(token: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            info = try await repository.fetchInfo(communityId: communityId, token: token)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Who to show after the admins and moderators: your connections who
    /// joined, or, with none, the latest to join. `roster` is the members the
    /// community page has loaded. A regular-member viewer comes first, as
    /// "You", so a community whose only regular member is you still shows one.
    func otherMembers(roster: [CommunityMember], viewerId: String) -> (people: [CommunityInfo.Person], line: String)? {
        guard let info else { return nil }
        if info.friendsCount > 0 {
            return (info.friends, Self.alsoMembers(info.friends.map(\.displayName),
                                                   total: info.friendsCount, connections: true))
        }
        let members = roster.filter { $0.role == .member }
        guard !members.isEmpty else { return nil }
        let viewer = members.first { $0.id == viewerId }
        let others = members.filter { $0.id != viewerId }.sorted { $0.joinedAt > $1.joinedAt }
        let shown = (viewer.map { [$0] } ?? []) + others.prefix(viewer == nil ? 5 : 4)
        let people = shown.map {
            CommunityInfo.Person(id: $0.id, displayName: $0.displayName, avatarUrl: $0.avatarUrl,
                                 avatarColor: $0.avatarColor, role: nil)
        }
        let names = shown.map { $0.id == viewerId ? Bundle.app.loc("You") : $0.displayName }
        // The roster is only the first page; the count covers everyone else.
        let total = max(members.count, info.memberCount - info.staff.count)
        if viewer != nil && total == 1 {
            return (people, Bundle.app.loc("You're a member."))
        }
        return (people, Self.alsoMembers(names, total: total, connections: false))
    }

    /// "Beso, Nguyệt and 3 other connections are also members."
    private static func alsoMembers(_ all: [String], total: Int, connections: Bool) -> String {
        let names = Array(all.prefix(2))
        let rest = total - names.count
        switch (names.count, rest) {
        case (1, 0):
            return String(format: Bundle.app.loc("%@ is also a member."), names[0])
        case (2, 0):
            return String(format: Bundle.app.loc("%@ and %@ are also members."), names[0], names[1])
        case (1, _):
            return String(format: Bundle.app.loc(connections ? "%@ and %lld other connections are also members."
                                                             : "%@ and %lld others are also members."), names[0], rest)
        default:
            return String(format: Bundle.app.loc(connections ? "%@, %@ and %lld other connections are also members."
                                                             : "%@, %@ and %lld others are also members."),
                          names[0], names[1], rest)
        }
    }

    /// "Rayleigh and Nam are admins. Linh is a moderator."
    var staffLine: String? {
        guard let info, !info.staff.isEmpty else { return nil }
        let admins = info.staff.filter { $0.role == "admin" }.map(\.displayName)
        let mods = info.staff.filter { $0.role == "moderator" }.map(\.displayName)
        var parts: [String] = []
        if !admins.isEmpty {
            parts.append(String(format: Bundle.app.loc(admins.count == 1 ? "%@ is an admin." : "%@ are admins."),
                                Self.join(admins)))
        }
        if !mods.isEmpty {
            parts.append(String(format: Bundle.app.loc(mods.count == 1 ? "%@ is a moderator." : "%@ are moderators."),
                                Self.join(mods)))
        }
        return parts.joined(separator: " ")
    }

    private static func join(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " " + Bundle.app.loc("and") + " " + names.last!
    }
}
