import Foundation
import Observation

@Observable
class JobViewModel {
    var jobData: JobData
    var isUpdating = false
    var errorMessage: String?

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
}
