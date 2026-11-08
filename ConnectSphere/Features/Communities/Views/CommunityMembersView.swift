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
            if currentUserRole == .admin && member.role == .member {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.updateRole(userId: member.id, newRole: .moderator) }
                } label: {
                    Label(bundle.loc("Promote to moderator"), systemImage: "person.badge.shield.checkmark")
                }
            }
            if currentUserRole == .admin && member.role == .moderator {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.updateRole(userId: member.id, newRole: .member) }
                } label: {
                    Label(bundle.loc("Demote to member"), systemImage: "person.badge.minus")
                }
            }

            // Kick
            if canKick {
                Divider()
                Button(role: .destructive) {
                    Task<Void, Never>(name: nil) { await viewModel.kickMember(member.id) }
                } label: {
                    Label(bundle.loc("Remove from community"), systemImage: "person.crop.circle.badge.xmark")
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
