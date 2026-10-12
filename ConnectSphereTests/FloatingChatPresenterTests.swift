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
}
