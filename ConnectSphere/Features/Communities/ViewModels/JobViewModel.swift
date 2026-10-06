import Foundation
import Observation

@Observable
class JobViewModel {
    var jobData: JobData
    var isUpdating = false
    var errorMessage: String?
    private(set) var isOpeningChat = false

    private let token: String
    private let client = NetworkClient.shared

    init(jobData: JobData, token: String) {
        self.jobData = jobData
        self.token   = token
    }

    func setInterested(_ interested: Bool) async {
        guard !isUpdating, jobData.userInterested != interested else { return }
        let snapshot = jobData

        jobData.userInterested = interested
        jobData.interestedCount = interested
            ? jobData.interestedCount + 1
            : max(0, jobData.interestedCount - 1)
        isUpdating = true

        do {
            let body = NetworkClient.encode(["interested": interested])
            _ = try await client.fetch(OKResponse.self,
                                        path: "/jobs/\(jobData.id)/interest",
                                        method: "POST", token: token, bodyData: body)
        } catch {
            jobData = snapshot
            errorMessage = friendlyError(error)
        }
        isUpdating = false
    }

    /// The conversation with the job's poster, or nil (fails silently — the
    /// user can tap Message again).
    func openConversation(with posterId: String, mode: AppMode) async -> String? {
        isOpeningChat = true
        defer { isOpeningChat = false }
        return try? await MessageRepository().openConversation(otherUserId: posterId, mode: mode.rawValue, token: token)
    }
}
