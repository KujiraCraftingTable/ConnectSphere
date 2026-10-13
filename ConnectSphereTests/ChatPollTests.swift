import Foundation
import Testing
@testable import ConnectSphere

/// The group poll model: decoding the server's shape, finding my vote among
/// the voters, shares, ending, and the at-once local vote.
struct ChatPollTests {
    private func poll(endsAt: String = "null") -> ChatPoll {
        let json = """
        {"ends_at": \(endsAt), "options": [
          {"id":"o1","text":"Phở","vote_count":2,"voters":[
            {"id":"u1","display_name":"An","avatar_url":null,"avatar_color":"#111111"},
            {"id":"ME","display_name":"Me","avatar_url":"/uploads/me.jpg","avatar_color":null}]},
          {"id":"o2","text":"Bún bò","vote_count":1,"voters":[
            {"id":"u2","display_name":"Bình","avatar_url":null,"avatar_color":null}]},
          {"id":"o3","text":"Cơm tấm","vote_count":0,"voters":[]}]}
        """
        return try! JSONDecoder.makeISO8601().decode(ChatPoll.self, from: Data(json.utf8))
    }

    @Test func decodesOptionsAndVoters() {
        let p = poll()
        #expect(p.options.map(\.text) == ["Phở", "Bún bò", "Cơm tấm"])
        #expect(p.totalVotes == 3)
        #expect(p.options[0].voters.map(\.displayName) == ["An", "Me"])
        #expect(p.endsAt == nil)
    }

    @Test func findsMyVoteIgnoringIdCase() {
        #expect(poll().myOptionID(userId: "me") == "o1")
        #expect(poll().myOptionID(userId: "nobody") == nil)
    }

    @Test func sharesAddUpToOne() {
        let p = poll()
        #expect(abs(p.options.map(p.share(of:)).reduce(0, +) - 1) < 0.0001)
        #expect(p.share(of: p.options[2]) == 0)
    }

    @Test func endsWhenItsTimeHasPassed() {
        #expect(poll(endsAt: "\"2020-01-01T00:00:00Z\"").hasEnded())
        #expect(!poll(endsAt: "\"2999-01-01T00:00:00Z\"").hasEnded())
        #expect(!poll().hasEnded())
    }

    @Test func aLocalVoteCountsAtOnce() {
        let voted = poll().votedLocally(optionId: "o3", userId: "u9")
        #expect(voted.options[2].voteCount == 1)
        #expect(voted.myOptionID(userId: "u9") == "o3")
        #expect(voted.totalVotes == 4)
    }

    @Test func aLocalVoteMovesFromTheOldChoice() {
        let moved = poll().votedLocally(optionId: "o2", userId: "me")
        #expect(moved.myOptionID(userId: "me") == "o2")
        #expect(moved.options[0].voteCount == 1)
        #expect(moved.options[1].voteCount == 2)
        #expect(moved.totalVotes == 3)
    }

    @Test func aLocalUndoTakesTheVoteBack() {
        let undone = poll().unvotedLocally(userId: "ME")
        #expect(undone.myOptionID(userId: "me") == nil)
        #expect(undone.options[0].voteCount == 1)
        #expect(undone.totalVotes == 2)
    }
}
