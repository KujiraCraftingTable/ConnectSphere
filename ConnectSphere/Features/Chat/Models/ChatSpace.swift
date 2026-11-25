import SwiftUI

// MARK: - Space
/// A private folder the user puts people and group chats in to organise
/// Messages ("Greenwich Uni", "Badminton"). Per mode; a person or group can be
/// in several spaces; nobody but the owner ever sees them.
struct ChatSpace: Identifiable, Decodable, Equatable {
    let id: String
    var name: String
    var color: SpaceColor
    let position: Int
    var memberIds: [String]
    /// Group chats in the space (only ones you're still in).
    var groupIds: [String]
    /// The same people with name and photo, so someone you haven't chatted
    /// with yet still shows in the space.
    var members: [SpaceMember]

    enum CodingKeys: String, CodingKey {
        case id, name, color, position, members
        case memberIds = "member_ids"
        case groupIds = "conversation_ids"
    }

    init(id: String, name: String, color: SpaceColor, position: Int = 0, memberIds: [String] = [],
         groupIds: [String] = [], members: [SpaceMember] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.position = position
        self.memberIds = memberIds
        self.groupIds = groupIds
        self.members = members
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = SpaceColor(rawValue: try c.decode(String.self, forKey: .color)) ?? .blue
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        memberIds = try c.decodeIfPresent([String].self, forKey: .memberIds) ?? []
        groupIds = try c.decodeIfPresent([String].self, forKey: .groupIds) ?? []
        members = (try? c.decodeIfPresent([SpaceMember].self, forKey: .members)) ?? []
    }

    // MARK: - Membership
    /// Ids compare case-insensitively: the server's text-cast ids are lower
    /// case, while ids that went through a Swift `UUID` come back upper case.
    func contains(_ userId: String) -> Bool {
        memberIds.contains { $0.caseInsensitiveCompare(userId) == .orderedSame }
    }

    func containsGroup(_ conversationId: String) -> Bool {
        groupIds.contains { $0.caseInsensitiveCompare(conversationId) == .orderedSame }
    }

    /// Whether this chat sits in the space: a group by its own id, a 1-on-1
    /// by the other person.
    func contains(_ conversation: Conversation) -> Bool {
        if conversation.isGroup { return containsGroup(conversation.id) }
        return conversation.otherUserId.map(contains) ?? false
    }
}

// MARK: - Space colors
/// The preset colours a space can take. The same keys the server allowlists.
/// System colours, so each stays legible in both light and dark mode.
enum SpaceColor: String, CaseIterable, Identifiable {
    // Declared in hue order. The picker shows them in this order as a spectrum.
    case red, rose, coral, orange, amber, yellow, lime, olive
    case green, forest, emerald, teal, cyan, sky, blue, navy
    case indigo, violet, purple, fuchsia, pink, brown, slate, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red:     return .red
        case .orange:  return .orange
        case .green:   return .green
        case .teal:    return .teal
        case .blue:    return .blue
        case .purple:  return .purple
        case .pink:    return .pink
        case .gray:    return .gray
        case .rose:    return Self.rgb(0xF43F5E)
        case .coral:   return Self.rgb(0xFF7F50)
        case .amber:   return Self.rgb(0xF59E0B)
        case .yellow:  return Self.rgb(0xEAB308)
        case .lime:    return Self.rgb(0x84CC16)
        case .emerald: return Self.rgb(0x10B981)
        case .cyan:    return Self.rgb(0x06B6D4)
        case .sky:     return Self.rgb(0x38BDF8)
        case .indigo:  return Self.rgb(0x6366F1)
        case .violet:  return Self.rgb(0x8B5CF6)
        case .fuchsia: return Self.rgb(0xD946EF)
        // Deep shades that would vanish on a dark background get a lighter
        // dark-mode twin, so the planet and the folder tint stay visible.
        case .olive:   return Self.rgb(0x6B7A1F, dark: 0xA3B23A)
        case .forest:  return Self.rgb(0x166534, dark: 0x2FAE5F)
        case .navy:    return Self.rgb(0x1E3A8A, dark: 0x4F72E3)
        case .brown:   return Self.rgb(0x8B5E3C, dark: 0xB98560)
        case .slate:   return Self.rgb(0x475569, dark: 0x94A3B8)
        }
    }

    /// Localization key, callers wrap it in `bundle.loc(...)`.
    var label: String { rawValue.capitalized }

    private static func rgb(_ hex: UInt32, dark: UInt32? = nil) -> Color {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        guard let dark else { return Color(uiColor: ui(hex)) }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(hex) })
    }
}

// MARK: - Space members
/// Someone in a space, as the server lists them (persona for the space's mode).
struct SpaceMember: Identifiable, Decodable, Equatable {
    let id: String
    let displayName: String
    let avatarUrl: String?
    let avatarColor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarUrl   = "avatar_url"
        case avatarColor = "avatar_color"
    }
}

// MARK: - Inbox sections
/// One section of Messages while the Spaces view is on.
struct SpaceSection: Identifiable, Equatable {
    enum Kind: Equatable {
        case space(ChatSpace)
        /// Every chat in no space.
        case others
    }

    /// A space shows its people's chats, then the people you haven't
    /// messaged yet, they're in the folder all the same.
    enum Row: Identifiable, Equatable {
        case chat(Conversation)
        case person(SpaceMember)

        var id: String {
            switch self {
            case .chat(let c): return "chat-\(c.id)"
            case .person(let p): return "person-\(p.id.lowercased())"
            }
        }
    }

    let kind: Kind
    let rows: [Row]

    var id: String {
        if case .space(let space) = kind { return space.id }
        return "others"
    }

    var conversations: [Conversation] {
        rows.compactMap { if case .chat(let c) = $0 { return c } else { return nil } }
    }

    var unreadCount: Int { conversations.reduce(0) { $0 + $1.unreadCount } }

    /// Groups the conversation list by space, keeping the list's own order
    /// inside each section, then adds the space's people who have no chat
    /// yet. A person or group in two spaces appears in both; every chat in no
    /// space goes to the final "Other chats" section, so turning the view on
    /// never hides a chat.
    static func make(conversations: [Conversation], spaces: [ChatSpace]) -> [SpaceSection] {
        var placed = Set<String>()
        var sections: [SpaceSection] = spaces.map { space in
            let chats = conversations.filter(space.contains)
            placed.formUnion(chats.map(\.id))
            let chatting = Set(chats.compactMap { $0.otherUserId?.lowercased() })
            let waiting = space.members.filter { !chatting.contains($0.id.lowercased()) }
            return SpaceSection(kind: .space(space), rows: chats.map(Row.chat) + waiting.map(Row.person))
        }
        let others = conversations.filter { !placed.contains($0.id) }
        if !others.isEmpty || spaces.isEmpty {
            sections.append(SpaceSection(kind: .others, rows: others.map(Row.chat)))
        }
        return sections
    }
}

// MARK: - Space candidates
/// Someone who can be put in a space: anyone you have an accepted 1-on-1 chat
/// with in this mode, plus your connections (the server enforces the same).
struct SpaceCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let avatarUrl: String?
    let avatarColor: String?
    let subtitle: String?
    var isGroup = false

    /// Chat partners first (most recent first), then connections not already listed.
    static func merge(conversations: [Conversation], connections: [ConnectionItemDTO]) -> [SpaceCandidate] {
        var seen = Set<String>()
        var result: [SpaceCandidate] = []
        // A chat still at the request stage (either way) doesn't qualify yet:
        // nobody can be filed into a space before they've been accepted.
        for conversation in conversations where conversation.requestState == nil {
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

    /// Your group chats in this mode, most recent first.
    static func groups(from conversations: [Conversation]) -> [SpaceCandidate] {
        conversations.compactMap { conversation in
            guard case .group(let name, let avatar, let color, let count) = conversation.peer else { return nil }
            return SpaceCandidate(id: conversation.id, name: name, avatarUrl: avatar, avatarColor: color,
                                  subtitle: String(format: Bundle.app.loc("%lld members"), count), isGroup: true)
        }
    }
}
