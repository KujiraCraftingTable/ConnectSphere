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

    /// Chấp nhận lời mời đang chờ (mình là addressee)
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

    /// Từ chối lời mời đang chờ (mình là addressee)
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

    /// Hủy request mình đã gửi
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

    /// Gỡ kết nối đã accepted (cả 2 phía đều gỡ được)
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

struct ConnectButton: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var vm = ConnectViewModel()
    @State private var showDisconnectConfirm = false

    let targetUserId: String
    var compact: Bool = false   // true = hiện kế bên tên, nhỏ hơn

    /// Nội dung phụ hiển thị cùng lúc (vd: nút Nhắn tin ở profile header).
    /// Khi trạng thái cần 2 nút Accept/Decline, companion được đặt lên trên và
    /// 2 nút đó xuống hàng riêng bên dưới để tránh chen chúc/xuống dòng chữ.
    var companion: (() -> AnyView)? = nil

    /// Nhãn nút gửi lời mời theo mode: sở thích = "Kết bạn", công việc = "Kết nối"
    private var connectLabel: String {
        appState.currentMode == .hobby ? bundle.loc("Add friend") : bundle.loc("Connect")
    }

    /// Chiều rộng tối thiểu cho các chip trạng thái đơn (Kết bạn/Đã gửi/Đã kết nối)
    /// để chúng đồng nhất kích thước. Chỉ áp ở dạng đầy đủ (không compact).
    private var singleChipMinWidth: CGFloat? { compact ? nil : 112 }

    var body: some View {
        Group {
            switch vm.status {
            case .self:
                if let companion { companion() }
            case .accepted:
                withCompanion { connectedChip }
            case .pendingSent:
                withCompanion {
                    actionChip(label: bundle.loc("Sent"), icon: "clock", color: AppTheme.textSecondary,
                               minWidth: singleChipMinWidth) {
                        Task { await vm.cancel() }
                    }
                }
            case .pendingReceived:
                // Họ đã gửi lời mời cho mình → chấp nhận hoặc từ chối.
                // Companion (nếu có) nằm hàng trên, 2 nút này luôn cùng 1 hàng riêng bên dưới.
                let acceptDecline = HStack(spacing: 6) {
                    actionChip(label: bundle.loc("Accept"), icon: "checkmark",
                               color: themeManager.theme.primary) {
                        Task { await vm.accept() }
                    }
                    actionChip(label: bundle.loc("Decline"), icon: "xmark", color: .red) {
                        Task { await vm.decline() }
                    }
                }
                if let companion {
                    VStack(alignment: .trailing, spacing: 8) {
                        companion()
                        acceptDecline
                    }
                } else {
                    acceptDecline
                }
            case .none:
                withCompanion {
                    actionChip(label: connectLabel, icon: "person.badge.plus",
                               color: themeManager.theme.primary, minWidth: singleChipMinWidth) {
                        Task {
                            await vm.sendRequest(
                                targetId: targetUserId,
                                mode: appState.currentMode.rawValue
                            )
                        }
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
        .alert(bundle.loc("Error"), isPresented: .constant(vm.errorMessage != nil)) {
            Button(bundle.loc("OK")) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    /// Đặt companion (nếu có) cạnh chip trạng thái, cùng 1 hàng — dùng cho các
    /// trạng thái chỉ có 1 chip (connected/sent/none), không cần xuống hàng riêng.
    @ViewBuilder
    private func withCompanion<C: View>(@ViewBuilder _ chip: () -> C) -> some View {
        if let companion {
            HStack(spacing: 8) { chip(); companion() }
        } else {
            chip()
        }
    }

    // Kiểu nút "Friends" của Facebook: nền xám đặc + chữ đậm (tương phản tốt),
    // bấm vào để hỏi xác nhận gỡ kết nối.
    private var connectedChip: some View {
        Button {
            showDisconnectConfirm = true
        } label: {
            HStack(spacing: 4) {
                if vm.isLoading {
                    ProgressView().scaleEffect(compact ? 0.6 : 0.7)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: compact ? 10 : 11, weight: .bold))
                }
                Text("Connected", bundle: bundle)
                    .font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(AppColors.textPrimary(colorScheme))
            .padding(.horizontal, compact ? 8 : 14)
            .padding(.vertical, compact ? 3 : 7)
            .frame(minWidth: singleChipMinWidth)
            .background(Capsule().fill(AppColors.elevated(colorScheme)))
        }
        .buttonStyle(.plain)
        .disabled(vm.isLoading)
        .confirmationDialog(
            bundle.loc("Disconnect from this person?"),
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button(bundle.loc("Disconnect"), role: .destructive) {
                Task { await vm.remove() }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
    }

    // minWidth: chiều rộng tối thiểu để các trạng thái đơn (Kết bạn / Đã gửi)
    // có cùng kích thước dù nội dung khác nhau — canh theo nút rộng nhất.
    private func actionChip(label: String, icon: String, color: Color,
                             minWidth: CGFloat? = nil,
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
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(color == themeManager.theme.primary ? .white : color)
            .padding(.horizontal, compact ? 8 : 14)
            .padding(.vertical, compact ? 3 : 7)
            .frame(minWidth: minWidth)
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
