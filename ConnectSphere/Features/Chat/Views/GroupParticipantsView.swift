import SwiftUI

/// Member list + management for a group conversation. Adapted from
/// `CommunityDetailView`'s member section (`membersContent`/`memberRow`/
/// `memberContextMenu`), simplified from Communities' 3-tier
/// admin/moderator/member to this feature's 2-tier owner/member model.
/// Owner sees "Remove from group"/"Make owner" on other rows; any member
/// sees "Leave group" on their own row.
struct GroupParticipantsView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    let conversationId: String
    let token: String

    @State private var viewModel: GroupParticipantsViewModel
    @State private var showAddMembers = false
    @State private var showLeaveConfirm = false
    @State private var promoteTarget: GroupMember?

    init(conversationId: String, token: String) {
        self.conversationId = conversationId
        self.token = token
        _viewModel = State(initialValue: GroupParticipantsViewModel(conversationId: conversationId, token: token))
    }

    private var currentUserId: String { appState.currentUser?.id ?? "" }
    private var isOwner: Bool {
        viewModel.members.first(where: { $0.id == currentUserId })?.isOwner ?? false
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.members.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { membersContent }
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Participants"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOwner {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddMembers = true } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
        }
        .task { await viewModel.fetchMembers() }
        .sheet(isPresented: $showAddMembers) {
            GroupMemberPickerView(
                excludedUserIds: Set(viewModel.members.map(\.id)),
                remainingSlots: max(0, 100 - viewModel.members.count),
                confirmTitle: bundle.loc("Add"),
                onConfirm: { ids in
                    Task { await viewModel.addMembers(Array(ids)) }
                }
            )
            .environment(appState)
        }
        .confirmationDialog(bundle.loc("Leave this group?"), isPresented: $showLeaveConfirm, titleVisibility: .visible) {
            Button(bundle.loc("Leave"), role: .destructive) {
                Task { await viewModel.leaveGroup() }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        .alert(bundle.loc("Make owner?"), isPresented: Binding(
            get: { promoteTarget != nil },
            set: { if !$0 { promoteTarget = nil } }
        )) {
            Button(bundle.loc("Cancel"), role: .cancel) { promoteTarget = nil }
            Button(bundle.loc("Make owner")) {
                if let target = promoteTarget {
                    Task { await viewModel.promoteToOwner(target.id) }
                }
                promoteTarget = nil
            }
        } message: {
            Text("You will no longer be the owner of this group.", bundle: bundle)
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.error != nil)) {
            Button(bundle.loc("OK")) { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
        .onChange(of: viewModel.didLeave) { _, left in
            if left { dismiss() }
        }
    }

    // MARK: - Members

    private var membersContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.members) { member in
                memberRow(member)
                Divider().padding(.leading, 60)
            }
        }
        .padding(.top, 8)
    }

    private func memberRow(_ member: GroupMember) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: member.avatarColor))
                Text(String(member.displayName.prefix(1)))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text("@\(member.username)")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }

            Spacer()

            if member.isOwner {
                Text(bundle.loc("Owner"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(themeManager.theme.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(themeManager.theme.primary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { memberContextMenu(member) }
    }

    @ViewBuilder
    private func memberContextMenu(_ member: GroupMember) -> some View {
        let isSelf = member.id == currentUserId

        if isOwner && !isSelf {
            Button {
                promoteTarget = member
            } label: {
                Label(bundle.loc("Make owner"), systemImage: "crown")
            }
            Divider()
            Button(role: .destructive) {
                Task { await viewModel.kickMember(member.id) }
            } label: {
                Label(bundle.loc("Remove from group"), systemImage: "person.crop.circle.badge.xmark")
            }
        }

        if isSelf {
            Button(role: .destructive) {
                showLeaveConfirm = true
            } label: {
                Label(bundle.loc("Leave group"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}
