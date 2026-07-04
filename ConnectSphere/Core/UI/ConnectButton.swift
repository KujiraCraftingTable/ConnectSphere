import SwiftUI
import Combine
import Observation

enum ConnectionStatus {
    case none           // chưa kết nối
    case pendingSent    // mình đã gửi, chờ họ accept
    case pendingReceived // họ gửi cho mình, chờ mình accept
    case accepted       // đã kết nối
    case `self`         // chính mình
}

/// Button hiển thị trạng thái kết nối + xử lý gửi/hủy/chấp nhận/từ chối request.
/// Mọi request đều gắn Bearer token — backend xác định danh tính từ JWT.
@MainActor
@Observable
class ConnectViewModel {
    var status: ConnectionStatus = .none
    var connectionId: String? = nil
    var isLoading = false

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

    func load(viewerId: String, targetId: String, mode: String = "friend") async {
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
        if let res = try? await client.fetch(
            StatusResponse.self,
            path: "/connections/request",
            method: "POST",
            token: token,
            bodyData: body
        ) {
            apply(res)
        }
    }

    /// Chấp nhận lời mời đang chờ (mình là addressee)
    func accept() async {
        guard let token = authToken(), let connId = connectionId else { return }
        isLoading = true
        defer { isLoading = false }

        struct Res: Decodable { let status: String }
        let body = NetworkClient.encode(["connection_id": connId])
        if (try? await client.fetch(
            Res.self, path: "/connections/accept", method: "POST", token: token, bodyData: body
        )) != nil {
            status = .accepted
        }
    }

    /// Từ chối lời mời đang chờ (mình là addressee)
    func decline() async {
        guard let token = authToken(), let connId = connectionId else { return }
        isLoading = true
        defer { isLoading = false }

        struct Res: Decodable { let status: String }
        let body = NetworkClient.encode(["connection_id": connId])
        if (try? await client.fetch(
            Res.self, path: "/connections/decline", method: "POST", token: token, bodyData: body
        )) != nil {
            status = .none
            connectionId = nil
        }
    }

    /// Hủy request mình đã gửi
    func cancel() async {
        guard let token = authToken(), let connId = connectionId else { status = .none; return }
        isLoading = true
        defer { isLoading = false }

        struct Res: Decodable { let status: String }
        let body = NetworkClient.encode(["connection_id": connId])
        _ = try? await client.fetch(
            Res.self, path: "/connections/cancel", method: "POST", token: token, bodyData: body
        )
        status = .none
        connectionId = nil
    }
}

struct ConnectButton: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @State private var vm = ConnectViewModel()

    let targetUserId: String
    var compact: Bool = false   // true = hiện kế bên tên, nhỏ hơn

    var body: some View {
        Group {
            switch vm.status {
            case .self:     EmptyView()
            case .accepted: connectedChip
            case .pendingSent:
                actionChip(label: bundle.loc("Đã gửi"), icon: "clock", color: AppTheme.textSecondary) {
                    Task { await vm.cancel() }
                }
            case .pendingReceived:
                // Họ đã gửi lời mời cho mình → chấp nhận hoặc từ chối
                HStack(spacing: 6) {
                    actionChip(label: bundle.loc("Chấp nhận"), icon: "checkmark",
                               color: themeManager.theme.primary) {
                        Task { await vm.accept() }
                    }
                    actionChip(label: bundle.loc("Từ chối"), icon: "xmark", color: .red) {
                        Task { await vm.decline() }
                    }
                }
            case .none:
                actionChip(label: bundle.loc("Kết nối"), icon: "person.badge.plus",
                           color: themeManager.theme.primary) {
                    Task {
                        await vm.sendRequest(
                            targetId: targetUserId,
                            mode: appState.currentMode.rawValue
                        )
                    }
                }
            }
        }
        .task {
            if let me = appState.currentUser?.id {
                await vm.load(
                    viewerId: me,
                    targetId: targetUserId,
                    mode: appState.currentMode.rawValue
                )
            }
        }
    }

    private var connectedChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: compact ? 10 : 11, weight: .bold))
            Text("Đã kết nối", bundle: bundle)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
        }
        .foregroundColor(.green)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(Capsule().fill(Color.green.opacity(0.12)))
    }

    private func actionChip(label: String, icon: String, color: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if vm.isLoading {
                    ProgressView().scaleEffect(compact ? 0.6 : 0.7)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
            }
            .foregroundColor(color == themeManager.theme.primary ? .white : color)
            .padding(.horizontal, compact ? 8 : 14)
            .padding(.vertical, compact ? 3 : 7)
            .background(
                Capsule().fill(
                    color == themeManager.theme.primary
                        ? AnyShapeStyle(color)
                        : AnyShapeStyle(color.opacity(0.12))
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(vm.isLoading)
    }
}
