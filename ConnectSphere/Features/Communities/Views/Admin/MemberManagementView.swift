import SwiftUI

/// Dedicated member-management screen (kick / change role) for admins.
/// In CommunityDetailView, admins get a context menu directly on member rows
/// (see CommunityDetailView); this view is used as a full-page fallback.
struct MemberManagementView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    let members: [CommunityMember]
    let currentUserRole: MemberRole
    let coverColor: String
    let onKick: (String) -> Void
    let onUpdateRole: (String, MemberRole) -> Void

    var body: some View {
        List {
            ForEach(members) { member in
                memberRow(member)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Manage Members")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func memberRow(_ member: CommunityMember) -> some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle().fill(Color(hex: member.avatarColor))
                Text(String(member.displayName.prefix(1)))
                    .font(.system(size: 14, weight: .bold))
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

            // Role badge
            if member.role != .member {
                Text(member.role.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: coverColor))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: coverColor).opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            adminActions(for: member)
        }
    }

    @ViewBuilder
    private func adminActions(for member: CommunityMember) -> some View {
        // Role actions (admin only)
        if currentUserRole == .admin {
            if member.role == .member {
                Button {
                    onUpdateRole(member.id, .moderator)
                } label: {
                    Label(bundle.loc("Phong Điều hành viên"), systemImage: "person.badge.shield.checkmark")
                }
            } else if member.role == .moderator {
                Button {
                    onUpdateRole(member.id, .member)
                } label: {
                    Label(bundle.loc("Xóa Điều hành viên"), systemImage: "person.badge.minus")
                }
            }
        }

        // Kick (admin can kick anyone; moderator can only kick members)
        let canKick = currentUserRole == .admin
            || (currentUserRole == .moderator && member.role == .member)

        if canKick {
            Divider()
            Button(role: .destructive) {
                onKick(member.id)
            } label: {
                Label(bundle.loc("Xóa khỏi cộng đồng"), systemImage: "person.crop.circle.badge.xmark")
            }
        }
    }
}
