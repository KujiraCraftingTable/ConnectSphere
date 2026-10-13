import Foundation

/// A group chat poll (`messageType == .poll`; the question is the message's
/// content). Options come in order with who voted for each, oldest first —
/// the same payload goes to every member, so "my vote" is found by looking
/// for my id among the voters. One final vote per person, as on posts.
struct ChatPoll: Decodable, Equatable {
    let endsAt: Date?
    var options: [Option]

    struct Option: Decodable, Equatable, Identifiable {
        let id: String
        let text: String
        var voteCount: Int
        var voters: [Voter]

        enum CodingKeys: String, CodingKey {
            case id, text, voters
            case voteCount = "vote_count"
        }
    }

    struct Voter: Decodable, Equatable, Identifiable {
        let id: String
        let displayName: String
        let avatarUrl: String?
        let avatarColor: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case avatarColor = "avatar_color"
        }
    }

    enum CodingKeys: String, CodingKey {
        case options
        case endsAt = "ends_at"
    }

    var totalVotes: Int { options.reduce(0) { $0 + $1.voteCount } }

    /// The option `userId` voted for, if any.
    func myOptionID(userId: String) -> String? {
        options.first { option in option.voters.contains { $0.id.caseInsensitiveCompare(userId) == .orderedSame } }?.id
    }

    func hasEnded(now: Date = Date()) -> Bool {
        endsAt.map { $0 <= now } ?? false
    }

    /// Share of all votes, 0…1.
    func share(of option: Option) -> Double {
        totalVotes == 0 ? 0 : Double(option.voteCount) / Double(totalVotes)
    }

    /// `userId`'s vote for `optionId` applied locally, shown at once while the
    /// server confirms (the server's poll then replaces it).
    func votedLocally(optionId: String, userId: String) -> ChatPoll {
        var copy = self
        if let i = copy.options.firstIndex(where: { $0.id == optionId }) {
            copy.options[i].voteCount += 1
            copy.options[i].voters.append(Voter(id: userId, displayName: "", avatarUrl: nil, avatarColor: nil))
        }
        return copy
    }
}
