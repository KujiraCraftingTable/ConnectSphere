import Foundation
import Observation

@Observable
class EventViewModel {
    var eventData: EventData
    var isUpdating = false
    var errorMessage: String?

    private let token: String
    private let client = NetworkClient.shared

    init(eventData: EventData, token: String) {
        self.eventData = eventData
        self.token     = token
    }

    func rsvp(status: RsvpStatus) async {
        guard !isUpdating else { return }
        let snapshot = eventData

        let wasGoing = eventData.userRsvp == .going
        let isGoing  = status == .going
        eventData.userRsvp = status
        if !wasGoing && isGoing { eventData.rsvpCount += 1 }
        else if wasGoing && !isGoing { eventData.rsvpCount = max(0, eventData.rsvpCount - 1) }
        isUpdating = true

        do {
            let body = NetworkClient.encode(["status": status.rawValue])
            _ = try await client.fetch(OKResponse.self,
                                        path: "/events/\(eventData.id)/rsvp",
                                        method: "POST", token: token, bodyData: body)
        } catch {
            eventData = snapshot
            errorMessage = friendlyError(error)
        }
        isUpdating = false
    }
}
