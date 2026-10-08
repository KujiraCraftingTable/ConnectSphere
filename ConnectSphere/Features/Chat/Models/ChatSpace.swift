import SwiftUI

/// A private label the user puts on people to organise Messages ("Greenwich
/// Uni", "Badminton"). Per mode; one person can be in several spaces; nobody
/// but the owner ever sees them.
struct ChatSpace: Identifiable, Decodable, Equatable {
    let id: String
    var name: String
    var color: SpaceColor
    let position: Int
    var memberIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, color, position
        case memberIds = "member_ids"
    }

    init(id: String, name: String, color: SpaceColor, position: Int = 0, memberIds: [String] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.position = position
        self.memberIds = memberIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = SpaceColor(rawValue: try c.decode(String.self, forKey: .color)) ?? .blue
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        memberIds = try c.decodeIfPresent([String].self, forKey: .memberIds) ?? []
    }

    /// Ids compare case-insensitively: the server's text-cast ids are lower
    /// case, while ids that went through a Swift `UUID` come back upper case.
    func contains(_ userId: String) -> Bool {
        memberIds.contains { $0.caseInsensitiveCompare(userId) == .orderedSame }
    }
}

/// The preset colours a space can take — the same keys the server allowlists.
/// System colours, so each stays legible in both light and dark mode.
enum SpaceColor: String, CaseIterable, Identifiable {
    case blue, green, orange, red, purple, pink, teal, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue:   return .blue
        case .green:  return .green
        case .orange: return .orange
        case .red:    return .red
        case .purple: return .purple
        case .pink:   return .pink
        case .teal:   return .teal
        case .gray:   return .gray
        }
    }

    /// Localization key — callers wrap it in `bundle.loc(...)`.
    var label: String { rawValue.capitalized }
}

/// One section of Messages while the Spaces view is on.
struct SpaceSection: Identifiable, Equatable {
    enum Kind: Equatable {
        case space(ChatSpace)
        /// Everyone in no space, plus every group chat.
        case others
    }

    let kind: Kind
    let conversations: [Conversation]

    var id: String {
        if case .space(let space) = kind { return space.id }
        return "others"
    }

    var unreadCount: Int { conversations.reduce(0) { $0 + $1.unreadCount } }

    /// Groups the conversation list by space, keeping the list's own order
    /// inside each section. A person in two spaces appears in both; a 1-on-1
    /// chat with someone in no space, and every group chat, go to the final
    /// "Other chats" section — so turning the view on never hides a chat.
    /// Spaces with no matching chats still get a (empty) section.
    static func make(conversations: [Conversation], spaces: [ChatSpace]) -> [SpaceSection] {
        var placed = Set<String>()
        var sections: [SpaceSection] = spaces.map { space in
            let inSpace = conversations.filter { conversation in
                guard let other = conversation.otherUserId else { return false }
                return space.contains(other)
            }
            placed.formUnion(inSpace.map(\.id))
            return SpaceSection(kind: .space(space), conversations: inSpace)
        }
        let others = conversations.filter { !placed.contains($0.id) }
        if !others.isEmpty || spaces.isEmpty {
            sections.append(SpaceSection(kind: .others, conversations: others))
        }
        return sections
    }
}

/// Someone who can be put in a space: anyone you have a 1-on-1 chat with in
/// this mode, plus your connections.
struct SpaceCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let avatarUrl: String?
    let avatarColor: String?
    let subtitle: String?

    /// Chat partners first (most recent first), then connections not already listed.
    static func merge(conversations: [Conversation], connections: [ConnectionItemDTO]) -> [SpaceCandidate] {
        var seen = Set<String>()
        var result: [SpaceCandidate] = []
        for conversation in conversations {
            guard case .direct(let id, _, let name, let color, let avatar, let job, let nickname) = conversation.peer,
                  seen.insert(id.lowercased()).inserted else { continue }
            result.append(SpaceCandidate(id: id, name: nickname ?? name, avatarUrl: avatar,
                                         avatarColor: color, subtitle: job))
        }
        for item in connections where seen.insert(item.user.id.lowercased()).inserted {
            result.append(SpaceCandidate(id: item.user.id, name: item.user.displayName,
                                         avatarUrl: item.user.avatarUrl, avatarColor: item.user.avatarColor,
                                         subtitle: item.user.jobTitle ?? item.user.company))
        }
        return result
    }
}
