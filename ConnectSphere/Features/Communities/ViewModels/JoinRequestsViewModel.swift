import Foundation
import Observation

@Observable
class JoinRequestsViewModel {
    var requests: [JoinRequest] = []
    var isLoading = false
    var errorMessage: String?

    private let communityId: String
    private let token: String
    private let repository = CommunityRepository()
    private let ws = WebSocketClient.shared

    init(communityId: String, token: String) {
        self.communityId = communityId
        self.token       = token
    }

    // MARK: - WebSocket / Realtime

    /// Start listening for `join_request_created` — call from the view's
    /// `.onAppear`. This view is only ever pushed from an already-live
    /// `CommunityDetailView` (see `CommunityDetailView.swift`'s
    /// `showJoinRequests` navigation destination), which already holds this
    /// community's `community:<id>` room open for the lifetime of this
    /// screen — so no `leave_community` is emitted here; only
    /// `CommunityDetailViewModel` owns that. The `join_community` emit below
    /// is a defensive no-op re-join (Socket.IO room joins are idempotent),
    /// covering the edge case where this view somehow outlives the parent's
    /// room membership (e.g. after a reconnect race).
    func startListening() {
        ws.emit("join_community", communityId)

        ws.on("join_request_created", tag: "joinRequests") { [weak self] payload in
            guard let self,
                  let dict = payload as? [String: Any],
                  (dict["communityId"] as? String) == self.communityId else { return }
            // The payload only carries requesterId/requesterName, not the full
            // joined row (avatarColor, etc.) `JoinRequest` needs — refetch the
            // list rather than constructing a partial model, same pattern
            // `ChatViewModel` uses for `group_updated`/`member_added`.
            Task { await self.fetchRequests() }
        }
    }

    /// Stop listening — call from the view's `.onDisappear`. Does NOT leave
    /// the community room (see `startListening()`'s comment).
    func stopListening() {
        ws.off("join_request_created", tag: "joinRequests")
    }

    func fetchRequests() async {
        isLoading = true
        do {
            requests = try await repository.fetchJoinRequests(communityId: communityId, token: token)
        } catch {
            errorMessage = friendlyError(error)
        }
        isLoading = false
    }

    func approve(_ requestId: String) async { await review(requestId: requestId, status: "approved") }
    func reject(_ requestId: String)  async { await review(requestId: requestId, status: "rejected") }

    private func review(requestId: String, status: String) async {
        requests.removeAll { $0.id == requestId }
        do {
            try await repository.reviewJoinRequest(
                communityId: communityId, requestId: requestId, status: status, token: token
            )
        } catch {
            errorMessage = friendlyError(error)
            await fetchRequests()
        }
    }
}
