import Foundation
import Testing
@testable import ConnectSphere

@MainActor
struct SpacesInboxTests {
    /// A conversation row as the server sends it.
    private func conversation(_ id: String, other: String? = nil, group: Bool = false, unread: Int = 0,
                              pinned: Bool = false, archived: Bool = false, request: String? = nil) throws -> Conversation {
        var json: [String: Any] = [
            "id": id, "mode": "hobby", "is_group": group, "updated_at": "2026-10-08T09:00:00.000Z",
            "unread_count": unread,
        ]
        if group {
            json["name"] = "Group \(id)"; json["member_count"] = 3
        } else {
            json["other_user_id"] = other ?? "u-\(id)"; json["other_user_name"] = "Person \(id)"
            json["other_user_avatar_color"] = "#123456"
        }
        if pinned { json["pinned_at"] = "2026-10-08T08:00:00.000Z" }
        if archived { json["archived_at"] = "2026-10-08T08:00:00.000Z" }
        if let request { json["request_state"] = request; json["requests_left"] = 2 }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder.makeISO8601().decode(Conversation.self, from: data)
    }

    @Test func sectionsGroupBySpaceAndKeepEverythingElseInOtherChats() throws {
        let uni = ChatSpace(id: "s1", name: "Greenwich Uni", color: .teal, memberIds: ["U-A", "u-b"])
        let club = ChatSpace(id: "s2", name: "Badminton", color: .orange, memberIds: ["u-a"])
        let empty = ChatSpace(id: "s3", name: "Family", color: .pink)
        let convs = [try conversation("1", other: "u-a", unread: 2), try conversation("2", other: "u-b"),
                     try conversation("3", other: "u-c"), try conversation("4", group: true)]

        let sections = SpaceSection.make(conversations: convs, spaces: [uni, club, empty])
        #expect(sections.map(\.id) == ["s1", "s2", "s3", "others"])
        #expect(sections[0].conversations.map(\.id) == ["1", "2"])   // ids match case-insensitively
        #expect(sections[1].conversations.map(\.id) == ["1"])        // one person, two spaces
        #expect(sections[2].rows.isEmpty)                           // empty space still shows
        #expect(sections[3].conversations.map(\.id) == ["3", "4"])   // the rest, groups included
        #expect(sections[0].unreadCount == 2)
    }

    @Test func peopleWithoutAChatStillShowInTheirSpace() throws {
        let member = { (id: String) in SpaceMember(id: id, displayName: id, avatarUrl: nil, avatarColor: nil) }
        let uni = ChatSpace(id: "s1", name: "Uni", color: .teal, memberIds: ["u-a", "u-new"],
                            members: [member("U-A"), member("u-new")])
        let sections = SpaceSection.make(conversations: [try conversation("1", other: "u-a")], spaces: [uni])
        // The person you chat with appears once, as their chat; the other as a person.
        #expect(sections[0].rows.map(\.id) == ["chat-1", "person-u-new"])
        #expect(sections[0].conversations.map(\.id) == ["1"])
    }

    @Test func groupChatsInASpaceLeaveOtherChats() throws {
        let uni = ChatSpace(id: "s1", name: "Uni", color: .teal, memberIds: ["u-a"], groupIds: ["G-1"])
        let club = ChatSpace(id: "s2", name: "Club", color: .orange, groupIds: ["g-1"])
        let convs = [try conversation("g-1", group: true), try conversation("1", other: "u-a"),
                     try conversation("g-2", group: true)]
        let sections = SpaceSection.make(conversations: convs, spaces: [uni, club])
        #expect(sections[0].conversations.map(\.id) == ["g-1", "1"])   // list order kept, ids case-insensitive
        #expect(sections[1].conversations.map(\.id) == ["g-1"])        // one group, two spaces
        #expect(sections[2].conversations.map(\.id) == ["g-2"])        // only the unfiled group is left over
        #expect(uni.contains(convs[0]) && !club.contains(convs[1]))
    }

    @Test func groupCandidatesComeFromGroupChatsOnly() throws {
        let convs = [try conversation("1", other: "u-a"), try conversation("g-1", group: true)]
        let groups = SpaceCandidate.groups(from: convs)
        #expect(groups.map(\.id) == ["g-1"])
        #expect(groups.allSatisfy { $0.isGroup })
    }

    @Test func spacesDecodeTheirGroups() throws {
        let space = try JSONDecoder().decode(ChatSpace.self, from: Data("""
            {"id":"s1","name":"Uni","color":"navy","position":0,"member_ids":[],"conversation_ids":["g-1"],"members":[]}
            """.utf8))
        #expect(space.groupIds == ["g-1"] && space.color == .navy)
        let older = try JSONDecoder().decode(ChatSpace.self, from: Data("""
            {"id":"s1","name":"Uni","color":"blue","member_ids":[]}
            """.utf8))
        #expect(older.groupIds.isEmpty)
    }

    @Test func noSpacesMeansOneOtherChatsSection() throws {
        let sections = SpaceSection.make(conversations: [try conversation("1")], spaces: [])
        #expect(sections.count == 1 && sections[0].kind == .others)
    }

    @Test func candidatesAreChatPartnersThenConnectionsWithoutDuplicates() throws {
        let convs = [try conversation("1", other: "u-a"), try conversation("2", group: true)]
        let connection = try JSONDecoder.makeISO8601().decode(ConnectionItemDTO.self, from: Data("""
            {"connection_id":"c1","status":"accepted","mode":"hobby",
             "user":{"id":"U-A","username":"a","display_name":"A","avatar_color":"#111111"}}
            """.utf8))
        let other = try JSONDecoder.makeISO8601().decode(ConnectionItemDTO.self, from: Data("""
            {"connection_id":"c2","status":"accepted","mode":"hobby",
             "user":{"id":"u-z","username":"z","display_name":"Zed","avatar_color":"#222222"}}
            """.utf8))
        let candidates = SpaceCandidate.merge(conversations: convs, connections: [connection, other])
        #expect(candidates.map(\.id) == ["u-a", "u-z"])
    }

    @Test func pendingRequestsCannotBeFiledIntoSpaces() throws {
        let convs = [try conversation("1", other: "u-friend"), try conversation("2", other: "u-in", request: "waiting"),
                     try conversation("3", other: "u-out", request: "sent")]
        #expect(SpaceCandidate.merge(conversations: convs, connections: []).map(\.id) == ["u-friend"])
    }

    @Test func inboxArchiveAndWaitingAreSeparate() throws {
        let vm = ConversationListViewModel()
        vm.conversations = [try conversation("1", pinned: true), try conversation("2", archived: true),
                            try conversation("3", request: "waiting"), try conversation("4", request: "sent")]
        #expect(vm.inbox.map(\.id) == ["1", "4"])
        #expect(vm.archived.map(\.id) == ["2"])
        #expect(vm.waiting.map(\.id) == ["3"])
        #expect(vm.conversations[0].isPinned)
        #expect(vm.conversations[3].requestState == .sent && vm.conversations[3].requestsLeft == 2)
    }
}
