import SwiftUI
import Combine
import Observation

struct ConnectButton: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var vm: ConnectViewModel
    @State private var showDisconnectConfirm = false
    @State private var showUnsendConfirm = false

    let targetUserId: String
    var compact: Bool = false   // true = shown next to the name, smaller
    /// Accept / Decline split the full width between them, for a row of
    /// their own under a card's header.
    var fullWidth: Bool = false

    /// Secondary content shown alongside (e.g. the Message button in the profile header).
    /// When the status needs 2 buttons (Accept/Decline), the companion is placed above and
    /// those 2 buttons go on their own row below, to avoid crowding/text wrapping.
    var companion: (() -> AnyView)? = nil

    /// `sharedVM` lets the owner read the status too (e.g. a search card that
    /// moves Accept / Decline to their own row); by default it has its own.
    init(targetUserId: String, compact: Bool = false, fullWidth: Bool = false,
         sharedVM: ConnectViewModel? = nil, companion: (() -> AnyView)? = nil) {
        self.targetUserId = targetUserId
        self.compact = compact
        self.fullWidth = fullWidth
        self.companion = companion
        _vm = State(initialValue: sharedVM ?? ConnectViewModel())
    }

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
                        // A tap on "Sent" shouldn't silently take the request back.
                        showUnsendConfirm = true
                    }
                }
            case .pendingReceived:
                // They sent us the request → accept or decline it.
                // The companion (if any) sits on the row above, these 2 buttons always share their own row below.
                let acceptDecline = HStack(spacing: 6) {
                    actionChip(label: bundle.loc("Accept"), icon: "checkmark",
                               color: themeManager.theme.primary, stretches: fullWidth) {
                        Task { await vm.accept() }
                    }
                    actionChip(label: bundle.loc("Decline"), icon: "xmark", color: .red, stretches: fullWidth) {
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
                    .disabledWhenRestricted()
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
        .alert(bundle.loc("Unsend friend request?"), isPresented: $showUnsendConfirm) {
            Button(bundle.loc("Unsend"), role: .destructive) { Task { await vm.cancel() } }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        .alert(bundle.loc("Error"), isPresented: .constant(vm.errorMessage != nil)) {
            Button(bundle.loc("OK")) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    /// Places the companion (if any) next to the status chip, on the same row. Used for
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
    // are the same size despite different content. Sized to the widest button.
    // fixedWidth: exact width, used in the compact form to keep the chip from
    // resizing (and reflowing its neighbours) when the label swaps on tap.
    private func actionChip(label: String, icon: String, color: Color,
                             minWidth: CGFloat? = nil, fixedWidth: CGFloat? = nil, stretches: Bool = false,
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
            .frame(minWidth: minWidth, maxWidth: stretches ? .infinity : nil)
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
