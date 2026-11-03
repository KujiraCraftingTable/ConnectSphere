import SwiftUI

/// Dating, opened from the account menu: a space of its own, kept out of
/// normal search, with its own profile shared by Hobby and Work. Locked under
/// 16 (or with no birthday); otherwise Discover, Likes you and Matches.
struct DatingHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel = DatingHomeViewModel()
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var chat: DatingChatTarget?

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        content
            .background(AppColors.base(colorScheme).ignoresSafeArea())
            .navigationTitle(Text("Dating", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.profile != nil {
                    ToolbarItem(placement: .primaryAction) { profileMenu }
                }
            }
            .sheet(isPresented: $showEditor) {
                DatingProfileEditorView(profile: viewModel.profile, isTeen: viewModel.status?.isTeen ?? false) { saved in
                    Task<Void, Never>(name: nil) { await viewModel.profileSaved(saved, token: token) }
                }
                .environment(appState)
                .environment(themeManager)
            }
            .sheet(item: $viewModel.newMatch) { match in
                DatingMatchSheet(person: match.person) {
                    viewModel.newMatch = nil
                    if let id = match.conversationId { chat = DatingChatTarget(conversationId: id, person: match.person) }
                }
                .environment(themeManager)
                .presentationDetents([.medium])
            }
            .navigationDestination(item: $chat) { target in
                ChatView(
                    conversationId: target.conversationId,
                    peer: .direct(otherUserId: target.person.id, name: target.person.displayName,
                                  avatarColor: target.person.avatarColor ?? "", avatarUrl: target.person.photos.first),
                    currentUserId: appState.currentUser?.id ?? "",
                    token: token
                )
            }
            .confirmationDialog(bundle.loc("Delete your dating profile?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(bundle.loc("Delete"), role: .destructive) {
                    Task<Void, Never>(name: nil) { _ = await viewModel.deleteProfile(token: token) }
                }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            } message: {
                Text("Your photos, likes and matches are deleted, and chats that started in Dating go too. This can't be undone.",
                     bundle: bundle)
            }
            .alert(bundle.loc("Something went wrong."), isPresented: Binding(
                get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
                Button(bundle.loc("OK"), role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .task { await viewModel.load(token: token) }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.loadFailed {
            DatingEmptyState(icon: "wifi.exclamationmark", title: bundle.loc("Couldn't load Dating"),
                             message: bundle.loc("Check your connection and try again."))
                .overlay(alignment: .bottom) {
                    Button(bundle.loc("Try again")) {
                        Task<Void, Never>(name: nil) { await viewModel.load(token: token) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeManager.theme.primary)
                    .offset(y: 56)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isLoading || viewModel.status == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isLocked {
            // Not reachable from the menu under 16; the server refuses anyway.
            Color.clear
        } else if viewModel.needsProfile {
            DatingSetupView(basics: viewModel.status?.me, isTeen: viewModel.status?.isTeen ?? false) { saved in
                Task<Void, Never>(name: nil) { await viewModel.profileSaved(saved, token: token) }
            }
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $viewModel.tab) {
                    Text("Discover", bundle: bundle).tag(DatingHomeViewModel.Tab.discover)
                    Text(viewModel.likers.isEmpty ? bundle.loc("Likes you")
                         : String(format: bundle.loc("Likes you (%lld)"), viewModel.likers.count))
                        .tag(DatingHomeViewModel.Tab.likesYou)
                    Text("Matches", bundle: bundle).tag(DatingHomeViewModel.Tab.matches)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm)
                switch viewModel.tab {
                case .discover: discover
                case .likesYou: DatingLikesView(viewModel: viewModel, token: token)
                case .matches: DatingMatchesView(viewModel: viewModel, token: token) { match in
                    if let id = match.conversationId { chat = DatingChatTarget(conversationId: id, person: match.person) }
                }
                }
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            Button { showEditor = true } label: { Label(bundle.loc("Edit dating profile"), systemImage: "pencil") }
            if viewModel.profile?.isActive == true {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.setActive(false, token: token) }
                } label: { Label(bundle.loc("Take a break"), systemImage: "pause.circle") }
            } else {
                Button {
                    Task<Void, Never>(name: nil) { await viewModel.setActive(true, token: token) }
                } label: { Label(bundle.loc("Turn Dating back on"), systemImage: "play.circle") }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label(bundle.loc("Delete dating profile"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(Text("Dating settings", bundle: bundle))
    }

    // MARK: Discover

    @ViewBuilder
    private var discover: some View {
        ScrollView {
            VStack(spacing: AppSpacing.md) {
                if viewModel.profile?.isActive == false {
                    breakBanner
                }
                if viewModel.locationBlocked {
                    DatingLocationRequiredView {
                        Task<Void, Never>(name: nil) { await viewModel.refreshLocation(token: token) }
                    }
                } else if let card = viewModel.deck.first {
                    DatingCardView(card: card)
                        .id(card.id)
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    HStack(spacing: AppSpacing.xxl) {
                        respondButton(icon: "xmark", label: bundle.loc("Pass"), color: AppColors.textSecondary(colorScheme)) {
                            respond(card, liked: false)
                        }
                        respondButton(icon: "heart.fill", label: bundle.loc("Like"), color: themeManager.theme.primary) {
                            respond(card, liked: true)
                        }
                    }
                    .padding(.vertical, AppSpacing.sm)
                } else if viewModel.isLoadingDeck {
                    ProgressView().padding(.top, 80)
                } else {
                    emptyDeck
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xl)
            .animation(.easeOut(duration: 0.25), value: viewModel.deck.first?.id)
        }
        .refreshable { await viewModel.refreshAll(token: token) }
    }

    private func respond(_ card: DatingCard, liked: Bool) {
        Task<Void, Never>(name: nil) { await viewModel.respond(to: card, liked: liked, token: token) }
    }

    private func respondButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(color)
                .frame(width: 68, height: 68)
                .background(AppColors.surface(colorScheme), in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var breakBanner: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "pause.circle.fill").font(.system(size: 22)).foregroundColor(themeManager.theme.primary)
            Text("You're taking a break — no one new can see you. Your matches stay.", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer(minLength: 0)
            Button(bundle.loc("Turn on")) {
                Task<Void, Never>(name: nil) { await viewModel.setActive(true, token: token) }
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .padding(AppSpacing.md)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
    }

    private var emptyDeck: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "heart.circle").font(.system(size: 48)).foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No one new right now", bundle: bundle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text("Check back later, or widen your age range or distance.", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
            Button(bundle.loc("Edit dating profile")) { showEditor = true }
                .padding(.top, AppSpacing.xs)
        }
        .padding(.top, 80)
        .padding(.horizontal, AppSpacing.xl)
    }
}

/// The chat a match opens (presentation state only).
struct DatingChatTarget: Identifiable, Hashable {
    let conversationId: String
    let person: DatingCard
    var id: String { conversationId }

    static func == (a: Self, b: Self) -> Bool { a.conversationId == b.conversationId }
    func hash(into hasher: inout Hasher) { hasher.combine(conversationId) }
}

/// "It's a match!" — straight after the like that made it.
struct DatingMatchSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let person: DatingCard
    let onMessage: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Avatar(name: person.displayName, colorHex: person.avatarColor, imageURL: person.photos.first, diameter: 96)
            Text("It's a match!", bundle: bundle)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(themeManager.theme.primary)
            Text(String(format: bundle.loc("You and %@ like each other."), person.displayName))
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Button(action: onMessage) {
                Text("Send a message", bundle: bundle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(themeManager.theme.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(bundle.loc("Keep browsing")) { dismiss() }
        }
        .padding(AppSpacing.xl)
    }
}
