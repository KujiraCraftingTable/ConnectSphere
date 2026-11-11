import Foundation
import Observation

/// The current user's connections in one mode: requests received (accept /
/// decline inline), requests sent (cancel inline) and people already connected.
@MainActor
@Observable
final class ConnectionsListViewModel {
    private(set) var pendingRequests: [ConnectionItemDTO] = []
    private(set) var friends: [ConnectionItemDTO] = []
    /// Requests I sent that are still waiting for an answer.
    private(set) var sentRequests: [ConnectionItemDTO] = []
    private(set) var isLoading = false
    /// Requests with an accept/decline in flight.
    private(set) var processingIds: Set<String> = []
    var errorMessage: String?

    private let repository = ConnectionRepository()

    func load(mode: AppMode) async {
        isLoading = true
        defer { isLoading = false }
        async let pending = repository.fetchConnections(mode: mode.rawValue, status: "pending_received")
        async let accepted = repository.fetchConnections(mode: mode.rawValue, status: "accepted")
        async let sent = repository.fetchConnections(mode: mode.rawValue, status: "pending_sent")
        pendingRequests = (try? await pending) ?? []
        friends         = (try? await accepted) ?? []
        sentRequests    = (try? await sent) ?? []
    }

    /// Takes back a request I sent; on failure the list stays as it was.
    func cancel(_ item: ConnectionItemDTO, mode: AppMode) async {
        processingIds.insert(item.connectionId)
        defer { processingIds.remove(item.connectionId) }
        do {
            try await repository.cancel(connectionId: item.connectionId)
            sentRequests.removeAll { $0.connectionId == item.connectionId }
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// On failure the list stays as it was and the error is surfaced for a retry.
    func respond(_ item: ConnectionItemDTO, accept: Bool, mode: AppMode) async {
        processingIds.insert(item.connectionId)
        defer { processingIds.remove(item.connectionId) }
        do {
            if accept {
                try await repository.accept(connectionId: item.connectionId)
            } else {
                try await repository.decline(connectionId: item.connectionId)
            }
            await load(mode: mode)
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}
