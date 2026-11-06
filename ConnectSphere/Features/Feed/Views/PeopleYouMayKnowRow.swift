import SwiftUI

/// "People you may know" in the feed: a sideways row of cards, each with the
/// reason we think you know them, Connect, and ✕ to stop suggesting them.
struct PeopleYouMayKnowRow: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: PeopleSuggestionsViewModel
    let mode: AppMode
    /// 0 for the first appearance in this load, 1 for the second.
    let appearance: Int

    var body: some View {
        let cards = viewModel.cards(for: mode, appearance: appearance)
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("People you may know", bundle: bundle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                NavigationLink {
                    PeopleSuggestionsListView(viewModel: viewModel, mode: mode)
                        .environment(appState)
                        .environment(themeManager)
                } label: {
                    Text("See all", bundle: bundle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                }
            }
            .padding(.horizontal, AppSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: AppSpacing.sm) {
                    ForEach(cards) { person in
                        card(person)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, AppSpacing.md)
                .animation(.snappy, value: cards.map(\.id))
            }
        }
        .padding(.vertical, AppSpacing.md)
        .cardStyle()
        // Seen once it's been on screen and scrolled away, not the instant it
        // appears: a reload during launch would otherwise mark fresh cards
        // seen before anyone looked, and move them down the feed.
        .onDisappear { viewModel.markSeen(mode) }
    }

    private func card(_ person: PeopleSuggestion) -> some View {
        VStack(spacing: 8) {
            NavigationLink {
                UserProfileView(userId: person.id).environment(appState)
            } label: {
                VStack(spacing: 6) {
                    Avatar(name: person.displayName, colorHex: person.avatarColor, imageURL: person.avatarUrl, diameter: 72)
                    Text(person.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                    Text(PeopleSuggestionText.reason(person.reason, mode: mode, bundle: bundle))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                    if let percent = person.matchPercent {
                        MatchPercentBadge(percent: percent)
                    }
                }
            }
            .buttonStyle(.plain)

            connectButton(person)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: 150)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button { Task { await viewModel.dismiss(person, mode: mode) } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(format: bundle.loc("Don't suggest %@"), person.displayName)))
        }
    }

    private func connectButton(_ person: PeopleSuggestion) -> some View {
        let requested = viewModel.requested.contains(person.id)
        return Button { Task { await viewModel.connect(person, mode: mode) } } label: {
            Group {
                if viewModel.sending.contains(person.id) {
                    ProgressView().tint(.white)
                } else if requested {
                    Label(bundle.loc("Requested"), systemImage: "checkmark").labelStyle(.titleAndIcon)
                } else {
                    Label(bundle.loc("Add friend"), systemImage: "person.badge.plus").labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(requested ? AppColors.textSecondary(colorScheme) : .white)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(requested ? AnyShapeStyle(AppColors.surface(colorScheme)) : AnyShapeStyle(themeManager.theme.primary),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(requested)
    }
}

/// The card's one-line reason, localised.
enum PeopleSuggestionText {
    static func reason(_ reason: PeopleSuggestion.Reason, mode: AppMode, bundle: Bundle) -> String {
        switch reason {
        case .mutual(let n):
            return n == 1 ? bundle.loc("1 mutual friend") : String(format: bundle.loc("%lld mutual friends"), n)
        case .interest(let x): return String(format: bundle.loc("Also into %@"), x)
        case .skill(let x): return String(format: bundle.loc("Also skilled in %@"), x)
        case .company(let x): return String(format: bundle.loc("Also works at %@"), x)
        case .place(let x): return String(format: bundle.loc("Also in %@"), x)
        case .similar: return bundle.loc(mode == .work ? "Similar background" : "Similar interests")
        }
    }
}

/// "See all": every suggestion for this mode, as the same cards People
/// search uses, with how closely each profile matches yours.
struct PeopleSuggestionsListView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: PeopleSuggestionsViewModel
    let mode: AppMode

    var body: some View {
        let people = viewModel.suggestions(for: mode)
        Group {
            if people.isEmpty {
                EmptyStateView(systemImage: "person.2",
                               title: bundle.loc("No suggestions right now"),
                               message: bundle.loc("As you make friends, people you may know show up here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.sm) {
                        ForEach(people) { person in
                            card(person)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { await viewModel.dismiss(person, mode: mode) }
                                    } label: {
                                        Label(bundle.loc("Don't suggest"), systemImage: "xmark")
                                    }
                                }
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, AppSpacing.sm)
                    .animation(.snappy, value: people.map(\.id))
                }
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("People you may know"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refresh(mode) }
    }

    @ViewBuilder
    private func card(_ person: PeopleSuggestion) -> some View {
        let user = person.toUserProfile(mode: mode)
        if mode == .work {
            ColleagueSearchCard(user: user, matchPercent: person.matchPercent).environment(appState)
        } else {
            FriendSearchCard(user: user, matchPercent: person.matchPercent).environment(appState)
        }
    }
}
