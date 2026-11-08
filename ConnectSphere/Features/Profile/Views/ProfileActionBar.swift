import SwiftUI

/// The buttons at the bottom of someone else's profile card: the relationship
/// button, then Message. Friends / Requested / Respond / Following open a
/// Facebook-style bottom sheet of actions. Following is independent of
/// friendship, friends can unfollow each other and stay friends.
struct ProfileActionBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let targetUserId: String
    let targetName: String
    @Bindable var connect: ConnectViewModel
    let isOpeningChat: Bool
    /// The official account has followers, never friends or connections.
    var targetIsOfficial = false
    let onMessage: () -> Void

    @State private var showSheet = false
    @State private var confirmUnfriend = false

    private var mode: String { appState.currentMode.rawValue }
    private var isHobby: Bool { appState.currentMode == .hobby }
    /// Signed in as the official account: it follows and connects with no one.
    private var viewerIsOfficial: Bool { appState.currentUser?.isOfficial ?? false }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            // The official account neither connects nor writes first: it
            // answers from its inbox when someone messages it.
            if !viewerIsOfficial {
                primaryButton
                ProfileCardButton(title: bundle.loc("Message"), icon: "message.fill",
                                  prominent: connect.status == .accepted, isLoading: isOpeningChat,
                                  action: onMessage)
            }
        }
        .sheet(isPresented: $showSheet) { actionSheet }
        .alert(String(format: bundle.loc("Unfriend %@?"), targetName),
                            isPresented: $confirmUnfriend) {
            Button(bundle.loc("Unfriend"), role: .destructive) { Task { await connect.remove() } }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        .task {
            if let me = appState.currentUser?.id {
                await connect.load(viewerId: me, targetId: targetUserId, mode: mode)
            }
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { connect.errorMessage != nil },
            set: { if !$0 { connect.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text(connect.errorMessage ?? "")
        }
    }

    // MARK: Primary button

    @ViewBuilder
    private var primaryButton: some View {
        if targetIsOfficial {
            followButton
        } else {
            connectionButton
        }
    }

    @ViewBuilder
    private var followButton: some View {
        if connect.isFollowing {
            ProfileCardButton(title: bundle.loc("Following"), icon: "checkmark") { showSheet = true }
        } else {
            ProfileCardButton(title: bundle.loc("Follow"), icon: "plus", prominent: true) {
                Task { await connect.setFollowing(true, targetId: targetUserId, mode: mode) }
            }
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch connect.status {
        case .accepted:
            ProfileCardButton(title: bundle.loc(isHobby ? "Friends" : "Connected"),
                              icon: "person.fill.checkmark", isLoading: connect.isLoading) { showSheet = true }
        case .pendingSent:
            ProfileCardButton(title: bundle.loc("Requested"), icon: "clock",
                              isLoading: connect.isLoading) { showSheet = true }
        case .pendingReceived:
            ProfileCardButton(title: bundle.loc("Respond"), icon: "person.fill.questionmark",
                              prominent: true, isLoading: connect.isLoading) { showSheet = true }
        case .none where connect.acceptsRequests:
            ProfileCardButton(title: bundle.loc(isHobby ? "Add friend" : "Connect"), icon: "person.fill.badge.plus",
                              prominent: true, isLoading: connect.isLoading) {
                Task { await connect.sendRequest(targetId: targetUserId, mode: mode) }
            }
        case .none:
            // They turned friend requests off: following is what's on offer.
            followButton
        case .self:
            EmptyView()
        }
    }

    // MARK: Bottom sheet

    private struct SheetAction: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        var destructive = false
        let run: () -> Void
    }

    private var sheetActions: [SheetAction] {
        let follow = SheetAction(
            title: bundle.loc(connect.isFollowing ? "Unfollow" : "Follow"),
            icon: connect.isFollowing ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.plus"
        ) { Task { await connect.setFollowing(!connect.isFollowing, targetId: targetUserId, mode: mode) } }

        switch connect.status {
        case .accepted:
            return [
                SheetAction(title: bundle.loc("Unfriend"), icon: "person.fill.xmark", destructive: true) {
                    confirmUnfriend = true
                },
                follow,
            ]
        case .pendingSent:
            return [
                SheetAction(title: bundle.loc("Cancel request"), icon: "xmark.circle") {
                    Task { await connect.cancel() }
                },
                follow,
            ]
        case .pendingReceived:
            return [
                SheetAction(title: bundle.loc("Confirm"), icon: "checkmark.circle") { Task { await connect.accept() } },
                SheetAction(title: bundle.loc("Delete request"), icon: "trash", destructive: true) {
                    Task { await connect.decline() }
                },
                follow,
            ]
        default:
            return [follow]
        }
    }

    private var actionSheet: some View {
        let actions = sheetActions
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(actions) { action in
                Button {
                    showSheet = false
                    action.run()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: action.icon)
                            .scaledFont(18, .semibold)
                            .foregroundColor(action.destructive ? AppColors.danger(colorScheme) : AppColors.textPrimary(colorScheme))
                            .frame(width: 44, height: 44)
                            .background(AppColors.elevated(colorScheme), in: Circle())
                        Text(action.title)
                            .scaledFont(17, .medium)
                            .foregroundColor(action.destructive ? AppColors.danger(colorScheme) : AppColors.textPrimary(colorScheme))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.top, AppSpacing.xl)
        .presentationDetents([.height(CGFloat(actions.count) * 60 + 56)])
        .presentationDragIndicator(.visible)
    }
}
