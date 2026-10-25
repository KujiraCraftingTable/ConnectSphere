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

    /// "Beso, Nguyệt and 3 other connections have joined".
    var friendsLine: String? {
        guard let info, info.friendsCount > 0 else { return nil }
        let names = info.friends.prefix(2).map(\.displayName)
        let others = info.friendsCount - names.count
        switch (names.count, others) {
        case (1, 0): return String(format: Bundle.app.loc("%@ has joined"), names[0])
        case (2, 0): return String(format: Bundle.app.loc("%@ and %@ have joined"), names[0], names[1])
        case (1, _): return String(format: Bundle.app.loc("%@ and %lld other connections have joined"), names[0], others)
        default:     return String(format: Bundle.app.loc("%@, %@ and %lld other connections have joined"), names[0], names[1], others)
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
