import SwiftUI

/// "..." › Manage roles (admin only): search members by name, tap one, and
/// make them moderator, member or the admin. Every change asks first.
struct ManageRolesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ManageRolesViewModel
    /// The member whose options are showing.
    @State private var selected: CommunityMember?
    /// A change waiting for its confirmation.
    @State private var pending: PendingChange?
    /// Admin handed on: the community page updates the viewer's role.
    let onTransferred: () -> Void

    private enum PendingChange {
        case role(CommunityMember, MemberRole)
        case admin(CommunityMember)
        case ban(CommunityMember)
        case unban(BannedMember)
    }

    init(communityId: String, onTransferred: @escaping () -> Void) {
        _viewModel = State(initialValue: ManageRolesViewModel(communityId: communityId))
        self.onTransferred = onTransferred
    }

    private var token: String { appState.authToken ?? "" }
    private var myId: String { appState.currentUser?.id ?? "" }

    // MARK: - Body
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchField
                results
                bannedSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .appBackground()
        .navigationTitle(Text("Manage roles", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.search(token: token)
            await viewModel.loadBans(token: token)
        }
        .alert(selected?.displayName ?? "",
               isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
               presenting: selected) { member in
            if member.role == .member {
                Button(bundle.loc("Make moderator")) { pending = .role(member, .moderator) }
            }
            Button(bundle.loc("Make admin")) { pending = .admin(member) }
            if member.role == .moderator {
                Button(bundle.loc("Make member"), role: .destructive) { pending = .role(member, .member) }
            }
            Button(bundle.loc("Remove and ban"), role: .destructive) { pending = .ban(member) }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { member in
            Text(roleLine(member.role))
        }
        .alert(confirmTitle,
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { change in
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc("Confirm")) { Task { await apply(change) } }
        } message: { change in
            Text(confirmMessage(change))
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Search
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(AppColors.textTertiary(colorScheme))
            TextField(bundle.loc("Search members by name"), text: $viewModel.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: viewModel.query) { viewModel.queryChanged(token: token) }
            if viewModel.isSearching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .surfaceBackground()
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.results.isEmpty && !viewModel.isSearching {
            Text("No members found", bundle: bundle)
                .scaledFont(14)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.top, 30)
                .frame(maxWidth: .infinity)
        } else {
            roleSection("Admin", viewModel.results.filter { $0.role == .admin })
            roleSection("Moderators", viewModel.results.filter { $0.role == .moderator })
            roleSection("Members", viewModel.results.filter { $0.role == .member })
        }
    }

    // MARK: - Role sections
    /// One titled box per role; a role with nobody (or no search match) hides.
    @ViewBuilder
    private func roleSection(_ title: String, _ members: [CommunityMember]) -> some View {
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                LazyVStack(spacing: 0) {
                    ForEach(members) { member in
                        row(member)
                        if member.id != members.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
                .surfaceBackground()
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(bundle.loc(title))
            .scaledFont(13, .semibold)
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var bannedSection: some View {
        if !viewModel.banned.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Banned")
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.banned) { person in
                        HStack(spacing: 12) {
                            Avatar(name: person.displayName, colorHex: person.avatarColor ?? "#888888",
                                   imageURL: person.avatarUrl, diameter: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName).scaledFont(15, .medium)
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                Text("@\(person.username)").scaledFont(13)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            Spacer()
                            Button(bundle.loc("Unban")) { pending = .unban(person) }
                                .scaledFont(13, .semibold)
                                .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .surfaceBackground()
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Rows
    private func row(_ member: CommunityMember) -> some View {
        Button {
            // Not your own row, and the admin seat only moves through
            // Make admin on someone else.
            if member.id != myId && member.role != .admin { selected = member }
        } label: {
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func roleLine(_ role: MemberRole) -> String {
        role == .moderator ? bundle.loc("Currently a moderator.") : bundle.loc("Currently a member.")
    }

    private var confirmTitle: String {
        switch pending {
        case .admin(let m): return String(format: bundle.loc("Make %@ the admin?"), m.displayName)
        case .role(let m, .moderator): return String(format: bundle.loc("Make %@ a moderator?"), m.displayName)
        case .role(let m, _): return String(format: bundle.loc("Remove %@ as moderator?"), m.displayName)
        case .ban(let m): return String(format: bundle.loc("Remove and ban %@?"), m.displayName)
        case .unban(let p): return String(format: bundle.loc("Lift %@'s ban?"), p.displayName)
        case nil: return ""
        }
    }

    // MARK: - Confirm and apply
    private func confirmMessage(_ change: PendingChange) -> String {
        switch change {
        case .admin: return bundle.loc("A community has one admin. You'll become a moderator.")
        case .role(_, .moderator): return bundle.loc("Moderators can review posts, handle reports and remove members.")
        case .role: return bundle.loc("They'll stay in the community as a member.")
        case .ban: return bundle.loc("They'll be removed, can't join again, and won't see this community anywhere.")
        case .unban: return bundle.loc("They'll be able to find and join this community again.")
        }
    }

    private func apply(_ change: PendingChange) async {
        switch change {
        case .role(let member, let role):
            await viewModel.setRole(member, to: role, token: token)
        case .admin(let member):
            if await viewModel.makeAdmin(member, token: token) {
                onTransferred()
                dismiss()
            }
        case .ban(let member):
            await viewModel.ban(member, token: token)
        case .unban(let person):
            await viewModel.unban(person, token: token)
        }
    }
}
