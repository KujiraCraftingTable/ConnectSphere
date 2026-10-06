import Foundation
import Observation

enum ConnectionStatus {
    case none           // not connected
    case pendingSent    // we sent the request, waiting for them to accept
    case pendingReceived // they sent it to us, waiting for us to accept
    case accepted       // connected
    case `self`         // this is our own profile
}

/// Button that displays connection status + handles sending/canceling/accepting/declining a request.
/// Every request carries a Bearer token — the backend determines identity from the JWT.
@MainActor
@Observable
class ConnectViewModel {
    var status: ConnectionStatus = .none
    var connectionId: String? = nil
    var isLoading = false
    var errorMessage: String?

    private let client = NetworkClient.shared

    private struct StatusResponse: Decodable {
        let status: String
        let connectionId: String?
        enum CodingKeys: String, CodingKey {
            case status
            case connectionId = "connection_id"
        }
    }

    private func authToken() -> String? {
        KeychainHelper.load(forKey: KeychainHelper.tokenKey)
    }

    private func apply(_ res: StatusResponse) {
        connectionId = res.connectionId
        switch res.status {
        case "accepted":         status = .accepted
        case "pending_sent":     status = .pendingSent
        case "pending_received": status = .pendingReceived
        case "self":             status = .self
        default:                 status = .none
        }
    }

    func load(viewerId: String, targetId: String, mode: String = "hobby") async {
        guard viewerId != targetId else { status = .self; return }
        guard let token = authToken() else { return }
        isLoading = true
        defer { isLoading = false }

        if let res = try? await client.fetch(
            StatusResponse.self,
            path: "/connections/status/\(targetId)",
            token: token,
            queryItems: [URLQueryItem(name: "mode", value: mode)]
        ) {
            apply(res)
        }
    }

    func sendRequest(targetId: String, mode: String) async {
        guard let token = authToken() else { return }
        isLoading = true
        defer { isLoading = false }

        let body = NetworkClient.encode(["addressee_id": targetId, "mode": mode])
        do {
            let res = try await client.fetch(
                StatusResponse.self,
                path: "/connections/request",
                method: "POST",
                token: token,
                bodyData: body
            )
            apply(res)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Accepts the pending request (we're the addressee)
    func accept() async {
        guard let token = authToken(), let connId = connectionId else { return }
        isLoading = true
        defer { isLoading = false }

        struct Res: Decodable { let status: String }
        let body = NetworkClient.encode(["connection_id": connId])
        do {
            _ = try await client.fetch(
                Res.self, path: "/connections/accept", method: "POST", token: token, bodyData: body
            )
            status = .accepted
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Declines the pending request (we're the addressee)
    func decline() async {
        guard let token = authToken(), let connId = connectionId else { return }
        isLoading = true
        defer { isLoading = false }

        struct Res: Decodable { let status: String }
        let body = NetworkClient.encode(["connection_id": connId])
        do {
            _ = try await client.fetch(
                Res.self, path: "/connections/decline", method: "POST", token: token, bodyData: body
            )
            status = .none
            connectionId = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Cancels the request we sent
    func cancel() async {
        guard let token = authToken(), let connId = connectionId else { status = .none; return }
        isLoading = true
        defer { isLoading = false }

        struct Res: Decodable { let status: String }
        let body = NetworkClient.encode(["connection_id": connId])
        do {
            _ = try await client.fetch(
                Res.self, path: "/connections/cancel", method: "POST", token: token, bodyData: body
            )
            status = .none
            connectionId = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Removes an accepted connection (either side can remove it)
    func remove() async {
        guard let token = authToken(), let connId = connectionId else { return }
        isLoading = true
        defer { isLoading = false }

        struct Res: Decodable { let status: String }
        let body = NetworkClient.encode(["connection_id": connId])
        do {
            _ = try await client.fetch(
                Res.self, path: "/connections/remove", method: "POST", token: token, bodyData: body
            )
            status = .none
            connectionId = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}
