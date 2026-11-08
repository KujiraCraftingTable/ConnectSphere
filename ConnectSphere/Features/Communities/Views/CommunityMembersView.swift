import SwiftUI

/// A community's members, opened from "About this community" › See all.
/// Shares the community page's view model, so a promotion or removal here
/// shows there too.
struct CommunityMembersView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: CommunityDetailViewModel
    @State private var reportTargetId: String? = nil
    @State private var showReportMember = false
    @State private var newAdmin: CommunityMember? = nil
    /// Promote to moderator / demote to member, waiting for its confirmation.
    @State private var roleChange: RoleChange? = nil
    /// Remove (or remove and ban), waiting for its confirmation.
    @State private var removal: Removal? = nil

    private struct Removal { let member: CommunityMember; let ban: Bool }

    private struct RoleChange { let member: CommunityMember; let role: MemberRole }

    private var communityId: String { viewModel.community?.id ?? "" }
    private var accentColor: Color { themeManager.theme.primary }
    private var currentUserRole: MemberRole? { viewModel.community?.role }
    private var isStaff: Bool { currentUserRole == .admin || currentUserRole == .moderator }
    private var isPrivateLockedOut: Bool {
        viewModel.community.map { !$0.viewerCanRead } ?? false
    }

    var body: some View {
        ScrollView {
            content
        }
        .appBackground()
        .navigationTitle(Text("Members", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(format: bundle.loc("Make %@ the admin?"), newAdmin?.displayName ?? ""),
            isPresented: Binding(get: { newAdmin != nil }, set: { if !$0 { newAdmin = nil } }),
            presenting: newAdmin
        ) { member in
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc("Make admin")) {
                Task<Void, Never>(name: nil) {
                    await viewModel.transferAdmin(to: member.id, currentUserId: appState.currentUser?.id ?? "")
                }
            }
        } message: { _ in
            Text("A community has one admin. You'll become a moderator.", bundle: bundle)
        }
        .alert(
            roleChange.map { change in
                String(format: bundle.loc(change.role == .moderator ? "Make %@ a moderator?" : "Remove %@ as moderator?"),
                       change.member.displayName)
            } ?? "",
            isPresented: Binding(get: { roleChange != nil }, set: { if !$0 { roleChange = nil } }),
            presenting: roleChange
        ) { change in
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc("Confirm")) {
                Task<Void, Never>(name: nil) { await viewModel.updateRole(userId: change.member.id, newRole: change.role) }
            }
        } message: { change in
            Text(change.role == .moderator
                 ? bundle.loc("Moderators can review posts, handle reports and remove members.")
                 : bundle.loc("They'll stay in the community as a member."))
        }
        .alert(
            removal.map { r in
                String(format: bundle.loc(r.ban ? "Remove and ban %@?" : "Remove %@ from the community?"), r.member.displayName)
            } ?? "",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { r in
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc(r.ban ? "Remove and ban" : "Remove"), role: .destructive) {
                Task<Void, Never>(name: nil) {
                    if r.ban { await viewModel.banMember(r.member.id) } else { await viewModel.kickMember(r.member.id) }
                }
            }
        } message: { r in
            Text(r.ban ? bundle.loc("They'll be removed, can't join again, and won't see this community anywhere.")
                       : bundle.loc("They can join again later."))
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showReportMember) {
            if let memberId = reportTargetId {
                ReportSheet(subject: .communityMember(communityId: communityId, userId: memberId))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isPrivateLockedOut {
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .scaledFont(40)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                Text(bundle.loc("Members of a private community are only visible to its members."))
                    .scaledFont(15)
                    .multilineTextAlignment(.center)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.horizontal, 32)
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity)
        } else if viewModel.isLoadingMembers {
            ProgressView().padding(.top, 40).frame(maxWidth: .infinity)
        } else {
            // Staff first; everyone else split by whether you're connected.
            let staff = viewModel.members.filter { $0.role != .member }
            let friends = viewModel.members.filter { $0.role == .member && $0.isFriend }
            let others = viewModel.members.filter { $0.role == .member && !$0.isFriend }
            VStack(alignment: .leading, spacing: 0) {
                if !staff.isEmpty { group(bundle.loc("Admins & moderators"), staff) }
                if !friends.isEmpty { group(bundle.loc("Friends"), friends) }
                if !others.isEmpty { group(bundle.loc("Members"), others) }
            }
            .padding(.vertical, 10)
        }
    }

    private func group(_ title: String, _ members: [CommunityMember]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .scaledFont(13, .semibold)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 14)
            LazyVStack(spacing: 0) {
                ForEach(members) { member in
                    CommunityProfileLink(communityId: communityId, userId: member.id) {
                        memberRow(member)
                    }
                    if member.id != members.last?.id {
                        Divider()
                            .background(AppColors.borderSubtle(colorScheme))
                            .padding(.leading, 60)
                    }
                }
            }
            .surfaceBackground()
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
    }

    private func memberRow(_ member: CommunityMember) -> some View {
        HStack(spacing: 12) {
            Avatar(name: member.displayName, colorHex: member.avatarColor, imageURL: member.avatarUrl, diameter: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .scaledFont(15, .medium)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text("@\(member.username)")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer()
            if member.role != .member {
                Text(bundle.loc(member.role.label))
                    .scaledFont(11, .semibold)
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { memberContextMenu(member) }
    }

    @ViewBuilder
    private func memberContextMenu(_ member: CommunityMember) -> some View {
        let isSelf  = member.id == (appState.currentUser?.id ?? "")
        let canKick = currentUserRole == .admin
                   || (currentUserRole == .moderator && member.role == .member)

        // Staff actions (not on self)
        if isStaff && !isSelf {
            // Role change, admin only
            if currentUserRole == .admin {
                Button { newAdmin = member } label: {
                    Label(bundle.loc("Make admin"), systemImage: "crown")
                }
            }
            if currentUserRole == .admin && member.role == .member {
                Button {
                    roleChange = RoleChange(member: member, role: .moderator)
                } label: {
                    Label(bundle.loc("Promote to moderator"), systemImage: "person.badge.shield.checkmark")
                }
            }
            if currentUserRole == .admin && member.role == .moderator {
                Button {
                    roleChange = RoleChange(member: member, role: .member)
                } label: {
                    Label(bundle.loc("Demote to member"), systemImage: "person.badge.minus")
                }
            }

            // Kick
            if canKick {
                Divider()
                Button(role: .destructive) {
                    removal = Removal(member: member, ban: false)
                } label: {
                    Label(bundle.loc("Remove from community"), systemImage: "person.crop.circle.badge.xmark")
                }
                // Banning is the admin's alone.
                if currentUserRole == .admin {
                    Button(role: .destructive) {
                        removal = Removal(member: member, ban: true)
                    } label: {
                        Label(bundle.loc("Remove and ban"), systemImage: "nosign")
                    }
                }
            }
        }

        // Report, any member can report another member (not self)
        if !isSelf {
            Divider()
            Button {
                reportTargetId  = member.id
                showReportMember = true
            } label: {
                Label(bundle.loc("Report this member"), systemImage: "flag")
            }
        }
    }
}
