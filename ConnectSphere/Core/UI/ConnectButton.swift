import SwiftUI
import Combine
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

struct ConnectButton: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var vm = ConnectViewModel()
    @State private var showDisconnectConfirm = false

    let targetUserId: String
    var compact: Bool = false   // true = shown next to the name, smaller

    /// Secondary content shown alongside (e.g. the Message button in the profile header).
    /// When the status needs 2 buttons (Accept/Decline), the companion is placed above and
    /// those 2 buttons go on their own row below, to avoid crowding/text wrapping.
    var companion: (() -> AnyView)? = nil

    /// Send-request button label per mode: hobby = "Add friend", work = "Connect"
    private var connectLabel: String {
        appState.currentMode == .hobby ? bundle.loc("Add friend") : bundle.loc("Connect")
    }

    /// Minimum width for the single-status chips (Add friend/Sent/Connected)
    /// so they're all the same size. Only applied in the full (non-compact) form.
    private var singleChipMinWidth: CGFloat? { compact ? nil : 112 }

    /// Fixed width for the single-status chips in the *compact* form. Without it
    /// the chip resizes when its label swaps on tap (Add friend → Sent →
    /// Connected), which reflows the author name / job title / timestamp sitting
    /// next to it in the feed card and re-flashes the avatar. Pinning every
    /// single-status compact chip to one width keeps the row perfectly still
    /// through the whole connect lifecycle. 96pt clears the widest label in
    /// either language ("Add friend" / "Connected" / VI "Đã kết nối") plus the
    /// icon, spacing and padding.
    private var compactChipWidth: CGFloat? { compact ? 96 : nil }

    var body: some View {
        Group {
            switch vm.status {
            case .self:
                if let companion { companion() }
            case .accepted:
                withCompanion { connectedChip }
            case .pendingSent:
                withCompanion {
                    actionChip(label: bundle.loc("Sent"), icon: "clock", color: AppColors.textSecondary(colorScheme),
                               minWidth: singleChipMinWidth, fixedWidth: compactChipWidth) {
                        Task { await vm.cancel() }
                    }
                }
            case .pendingReceived:
                // They sent us the request → accept or decline it.
                // The companion (if any) sits on the row above, these 2 buttons always share their own row below.
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
                               color: themeManager.theme.primary,
                               minWidth: singleChipMinWidth, fixedWidth: compactChipWidth) {
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

    /// Places the companion (if any) next to the status chip, on the same row — used for
    /// statuses with only a single chip (connected/sent/none), which don't need their own row.
    @ViewBuilder
    private func withCompanion<C: View>(@ViewBuilder _ chip: () -> C) -> some View {
        if let companion {
            HStack(spacing: 8) { chip(); companion() }
        } else {
            chip()
        }
    }

    // Facebook-style "Friends" button: solid gray background + bold text (good contrast),
    // tapping it asks for confirmation before removing the connection.
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
            .frame(width: compactChipWidth)
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

    // minWidth: minimum width so the single-status states (Add friend / Sent)
    // are the same size despite different content — sized to the widest button.
    // fixedWidth: exact width, used in the compact form to keep the chip from
    // resizing (and reflowing its neighbours) when the label swaps on tap.
    private func actionChip(label: String, icon: String, color: Color,
                             minWidth: CGFloat? = nil, fixedWidth: CGFloat? = nil,
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
            .frame(width: fixedWidth)
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
