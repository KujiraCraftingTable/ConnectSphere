import Foundation
import Testing
@testable import ConnectSphere

/// The floating chat window's rules: four chats at most (the one used longest
/// ago gives way), unread counted from the last tap, the window moving to a
/// neighbour on close, and stashing.
@MainActor
struct FloatingChatPresenterTests {
    private let me = "me"

    private func message(_ id: String, from sender: String) -> Message {
        let json = """
        {"id":"\(id)","conversation_id":"c","sender_id":"\(sender)","content":"hi","message_type":"text","created_at":0}
        """
        return try! JSONDecoder().decode(Message.self, from: Data(json.utf8))
    }

    private func viewModel(_ conversation: String, messages: [Message] = []) -> ChatViewModel {
        let vm = ChatViewModel(conversationId: conversation, currentUserId: me, isGroup: false, otherUserId: "x", token: "")
        vm.messages = messages
        return vm
    }

    @discardableResult
    private func float(_ presenter: FloatingChatPresenter, _ id: String, messages: [Message] = []) -> FloatingBubbleState? {
        presenter.minimize(conversationId: id,
                           peer: .direct(otherUserId: "x", name: id, avatarColor: "#000000", avatarUrl: nil),
                           otherUserLocation: nil, currentUserId: me, token: "",
                           viewModel: viewModel(id, messages: messages))
    }

    @Test func aFifthChatClosesTheOneUsedLongestAgo() {
        let presenter = FloatingChatPresenter()
        for id in ["a", "b", "c", "d"] { float(presenter, id) }
        presenter.bubbles.first { $0.id == "b" }?.lastUsed = .distantPast
        let closed = float(presenter, "e")
        #expect(closed?.id == "b")
        #expect(presenter.bubbles.map(\.id) == ["a", "c", "d", "e"])
        #expect(presenter.active?.id == "e")
    }

    @Test func floatingTheSameChatAgainShowsItWithoutAddingOne() {
        let presenter = FloatingChatPresenter()
        float(presenter, "a"); float(presenter, "b")
        #expect(float(presenter, "a") == nil)
        #expect(presenter.bubbles.count == 2)
        #expect(presenter.active?.id == "a")
    }

    @Test func unreadCountsFromTheLastTapAndClearsOnTap() {
        let presenter = FloatingChatPresenter()
        float(presenter, "a", messages: [message("m1", from: "x")])
        let bubble = presenter.active!
        #expect(bubble.unreadCount == 0)   // what was there when floated is seen
        bubble.viewModel.messages += [message("m2", from: "x"), message("m3", from: "x"), message("m4", from: me)]
        #expect(bubble.unreadCount == 2)   // my own message isn't unread
        presenter.markSeen(bubble)
        #expect(bubble.unreadCount == 0)
    }

    @Test func edgeCountsAddUpTheChatsEachSide() {
        let presenter = FloatingChatPresenter()
        for id in ["a", "b", "c"] { float(presenter, id) }
        presenter.bubbles[0].viewModel.messages.append(message("a1", from: "x"))
        presenter.bubbles[2].viewModel.messages += [message("c1", from: "x"), message("c2", from: "x")]
        presenter.activate(presenter.bubbles[1])
        #expect(presenter.unreadBefore == 1)
        #expect(presenter.unreadAfter == 2)
        presenter.activateNeighbour(1)
        #expect(presenter.active?.id == "c")
        #expect(presenter.unreadBefore == 1)
        #expect(presenter.unreadAfter == 0)
    }

    @Test func closingTheChatOnScreenShowsANeighbour() {
        let presenter = FloatingChatPresenter()
        for id in ["a", "b", "c"] { float(presenter, id) }
        presenter.activate(presenter.bubbles[1])
        presenter.close(presenter.bubbles[1])
        #expect(presenter.active?.id == "c")
        presenter.close(presenter.active!)
        #expect(presenter.active?.id == "a")
        presenter.close(presenter.active!)
        #expect(presenter.bubbles.isEmpty)
        #expect(presenter.windowPosition == nil)
    }

    @Test func stashingClosesTheReplyBarAndFloatingAChatBringsItBack() {
        let presenter = FloatingChatPresenter()
        float(presenter, "a")
        presenter.toggleComposing(presenter.active!)
        presenter.playingVideoID = "v"
        presenter.stash(to: .trailing)
        #expect(presenter.isStashed)
        #expect(presenter.composingBubble == nil)
        #expect(presenter.playingVideoID == nil)
        float(presenter, "b")
        #expect(!presenter.isStashed)
    }

    // MARK: Adding from the window's "+"

    @Test func addedChatKeepsItsInboxUnreadCount() {
        let messages = [message("1", from: "x"), message("2", from: me), message("3", from: "x"), message("4", from: "x")]
        #expect(FloatingBubbleState.seenBaseline(messages: messages, unread: 0, currentUserId: me) == "4")
        #expect(FloatingBubbleState.seenBaseline(messages: messages, unread: 2, currentUserId: me) == "2")
        // All of the other person's messages unread, my own in between.
        #expect(FloatingBubbleState.seenBaseline(messages: messages, unread: 3, currentUserId: me) == nil)
        #expect(FloatingBubbleState.seenBaseline(messages: messages, unread: 9, currentUserId: me) == nil)
    }

    private func conversation(_ id: String, name: String, lastAt: Double, request: String? = nil,
                              archived: Bool = false) -> Conversation {
        var fields = """
        "id":"\(id)","mode":"hobby","is_group":false,"updated_at":\(lastAt),"last_message_at":\(lastAt),
        "other_user_id":"u-\(id)","other_user_name":"\(name)","unread_count":0
        """
        if let request { fields += ",\"request_state\":\"\(request)\"" }
        if archived { fields += ",\"archived_at\":1" }
        return try! JSONDecoder().decode(Conversation.self, from: Data("{\(fields)}".utf8))
    }

    @Test func pickerOffersAcceptedChatsNewestFirst() {
        let list = [
            conversation("a", name: "Kujira", lastAt: 10),
            conversation("b", name: "Bá khí", lastAt: 30),
            conversation("c", name: "Stranger", lastAt: 40, request: "waiting"),
            conversation("d", name: "Old friend", lastAt: 50, archived: true),
        ]
        #expect(FloatingChatAddViewModel.addable(list, query: "").map(\.id) == ["b", "a"])
        // Search ignores case and Vietnamese accents.
        #expect(FloatingChatAddViewModel.addable(list, query: "ba khi").map(\.id) == ["b"])
    }
}
