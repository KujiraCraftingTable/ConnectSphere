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

    func vote(optionId: String) async {
        guard pollData.userVote == nil, !isVoting else { return }
        let snapshot = pollData

        if let idx = pollData.options.firstIndex(where: { $0.id == optionId }) {
            pollData.options[idx].voteCount += 1
        }
        pollData.userVote = optionId
        isVoting = true

        do {
            let body = NetworkClient.encode(["optionId": optionId])
            _ = try await client.fetch(OKResponse.self,
                                        path: "/posts/\(postId)/poll/vote",
                                        method: "POST", token: token, bodyData: body)
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
