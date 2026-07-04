import Foundation
import Observation

@Observable
class CreateCommunityPostViewModel {
    var postType: PostType = .text
    var content: String = ""
    var isPosting = false
    var errorMessage: String?
    let maxLength = 2000

    var pollOptions: [String] = ["", ""]
    var pollEndsAt: Date? = nil
    var showPollEndDate = false

    var eventTitle: String = ""
    var eventLocation: String = ""
    var eventStartsAt: Date = Date().addingTimeInterval(3600)
    var eventEndsAt: Date? = nil
    var showEventEndDate = false

    private let client = NetworkClient.shared

    // MARK: - Validation

    var isValid: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch postType {
        case .text: return true
        case .poll:
            let valid = pollOptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return valid.count >= 2
        case .event:
            return !eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && eventStartsAt > Date()
        }
    }

    var remaining: Int { maxLength - content.count }

    // MARK: - Submit

    func submitPost(communityId: String, token: String, onSuccess: @escaping (CommunityPost) -> Void) async {
        guard isValid else { return }
        isPosting = true
        errorMessage = nil
        do {
            let post: CommunityPost
            switch postType {
            case .text:  post = try await submitText(communityId: communityId, token: token)
            case .poll:  post = try await submitPoll(communityId: communityId, token: token)
            case .event: post = try await submitEvent(communityId: communityId, token: token)
            }
            content = ""
            onSuccess(post)
        } catch {
            if case APIError.serverError(_, let msg) = error { errorMessage = msg }
            else { errorMessage = "Could not post. Please try again." }
        }
        isPosting = false
    }

    // MARK: - Private helpers

    private func submitText(communityId: String, token: String) async throws -> CommunityPost {
        let body = NetworkClient.encode([
            "content":   content.trimmingCharacters(in: .whitespacesAndNewlines),
            "post_type": "text",
        ])
        let res = try await client.fetch(DataResponse<CommunityPostDTO>.self,
                                          path: "/communities/\(communityId)/posts",
                                          method: "POST", token: token, bodyData: body)
        return res.data.toCommunityPost()
    }

    private func submitPoll(communityId: String, token: String) async throws -> CommunityPost {
        let validOptions = pollOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var dict: [String: Any] = [
            "content":   content.trimmingCharacters(in: .whitespacesAndNewlines),
            "post_type": "poll",
            "options":   validOptions,
        ]
        if showPollEndDate, let endsAt = pollEndsAt {
            dict["endsAt"] = ISO8601DateFormatter().string(from: endsAt)
        }
        let body = try? JSONSerialization.data(withJSONObject: dict)
        let res = try await client.fetch(DataResponse<CommunityPostDTO>.self,
                                          path: "/communities/\(communityId)/posts",
                                          method: "POST", token: token, bodyData: body)
        return res.data.toCommunityPost()
    }

    private func submitEvent(communityId: String, token: String) async throws -> CommunityPost {
        let iso = ISO8601DateFormatter()
        var eventDict: [String: Any] = [
            "title":    eventTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            "location": eventLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            "startsAt": iso.string(from: eventStartsAt),
        ]
        if showEventEndDate, let endsAt = eventEndsAt { eventDict["endsAt"] = iso.string(from: endsAt) }

        let dict: [String: Any] = [
            "content":   content.trimmingCharacters(in: .whitespacesAndNewlines),
            "post_type": "event",
            "eventData": eventDict,
        ]
        let body = try? JSONSerialization.data(withJSONObject: dict)
        let res = try await client.fetch(DataResponse<CommunityPostDTO>.self,
                                          path: "/communities/\(communityId)/posts",
                                          method: "POST", token: token, bodyData: body)
        return res.data.toCommunityPost()
    }
}
