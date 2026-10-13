import Foundation
import Observation

@Observable
class PollViewModel {
    var pollData: PollData
    var isVoting = false
    var errorMessage: String?

    private let postId: String
    private let token: String
    private let client = NetworkClient.shared

    init(postId: String, pollData: PollData, token: String) {
        self.postId   = postId
        self.pollData = pollData
        self.token    = token
    }

    /// The end shared by every option, if the poll has one.
    var endsAt: Date? { pollData.options.first?.endsAt }
    var hasEnded: Bool { endsAt.map { $0 <= Date() } ?? false }

    /// A tap on an option, as in chat polls: votes for it, moves your vote
    /// to it, or — on the option you already picked — takes the vote back.
    /// Shown at once, undone if the server refuses. Nothing changes once the
    /// poll has ended.
    func tap(optionId: String) async {
        guard !isVoting, !hasEnded else { return }
        let snapshot = pollData
        let undo = pollData.userVote == optionId

        if let old = pollData.userVote, let i = pollData.options.firstIndex(where: { $0.id == old }) {
            pollData.options[i].voteCount -= 1
        }
        if !undo, let i = pollData.options.firstIndex(where: { $0.id == optionId }) {
            pollData.options[i].voteCount += 1
        }
        pollData.userVote = undo ? nil : optionId
        errorMessage = nil
        isVoting = true

        do {
            if undo {
                _ = try await client.fetch(OKResponse.self, path: "/posts/\(postId)/poll/vote",
                                           method: "DELETE", token: token)
            } else {
                let body = NetworkClient.encode(["optionId": optionId])
                _ = try await client.fetch(OKResponse.self, path: "/posts/\(postId)/poll/vote",
                                           method: "POST", token: token, bodyData: body)
            }
        } catch {
            pollData = snapshot
            errorMessage = friendlyError(error)
        }
        isVoting = false
    }

    func percentage(for option: PollOption) -> Double {
        option.percentage(totalVotes: pollData.totalVotes)
    }
}
