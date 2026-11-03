import SwiftUI

/// "Likes you": people who liked you and whom you haven't answered. Liking
/// one back makes a match straight away.
struct DatingLikesView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: DatingHomeViewModel
    let token: String
    @State private var opened: DatingCard?

    var body: some View {
        List {
            ForEach(viewModel.likers) { liker in
                HStack(spacing: AppSpacing.md) {
                    Button { opened = liker.card } label: {
                        DatingPersonRow(card: liker.card)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    circleButton("xmark", color: AppColors.textSecondary(colorScheme), label: bundle.loc("Pass")) {
                        respond(liker.card, liked: false)
                    }
                    circleButton("heart.fill", color: themeManager.theme.primary, label: bundle.loc("Like back")) {
                        respond(liker.card, liked: true)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.likers.isEmpty {
                DatingEmptyState(icon: "heart", title: bundle.loc("No likes yet"),
                                 message: bundle.loc("When someone likes you, they'll show up here."))
            }
        }
        .refreshable { await viewModel.refreshLikes(token: token) }
        .sheet(item: $opened) { card in
            NavigationStack {
                ScrollView {
                    DatingCardView(card: card).padding(AppSpacing.lg)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Close")) { opened = nil } }
                    ToolbarItem(placement: .bottomBar) {
                        HStack(spacing: AppSpacing.xxl) {
                            Button(bundle.loc("Pass")) { opened = nil; respond(card, liked: false) }
                            Button(bundle.loc("Like back")) { opened = nil; respond(card, liked: true) }
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .environment(themeManager)
        }
    }

    private func respond(_ card: DatingCard, liked: Bool) {
        Task<Void, Never>(name: nil) { await viewModel.respond(to: card, liked: liked, token: token) }
    }

    private func circleButton(_ icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(color)
                .frame(width: 40, height: 40)
                .background(AppColors.elevated(colorScheme), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Your matches, newest first. Tap to chat; swipe to unmatch (it asks first).
struct DatingMatchesView: View {
    @Environment(\.appBundle) private var bundle

    let viewModel: DatingHomeViewModel
    let token: String
    let onOpen: (DatingMatch) -> Void
    @State private var unmatching: DatingMatch?

    var body: some View {
        List {
            ForEach(viewModel.matches) { match in
                Button { onOpen(match) } label: {
                    DatingPersonRow(card: match.person)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(bundle.loc("Unmatch")) { unmatching = match }
                        .tint(.red)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.matches.isEmpty {
                DatingEmptyState(icon: "heart.circle", title: bundle.loc("No matches yet"),
                                 message: bundle.loc("When you and someone like each other, you can chat here and in your Hobby messages."))
            }
        }
        .refreshable { await viewModel.refreshMatches(token: token) }
        .confirmationDialog(bundle.loc("Unmatch?"), isPresented: Binding(
            get: { unmatching != nil }, set: { if !$0 { unmatching = nil } }), titleVisibility: .visible,
            presenting: unmatching) { match in
            Button(bundle.loc("Unmatch"), role: .destructive) {
                Task<Void, Never>(name: nil) { await viewModel.unmatch(match, token: token) }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: { match in
            Text(String(format: bundle.loc("You and %@ won't see each other in Dating again. A chat that started from this match is deleted."),
                        match.person.displayName))
        }
    }
}

/// Photo, name and age, place — one person in a Dating list.
struct DatingPersonRow: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let card: DatingCard

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Avatar(name: card.displayName, colorHex: card.avatarColor, imageURL: card.photos.first, diameter: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(card.displayName), \(card.age)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(verbatim: card.city + " · " + String(format: bundle.loc("%lld km away"), card.distanceKm))
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DatingEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: icon).font(.system(size: 44)).foregroundColor(AppColors.textTertiary(colorScheme))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(AppSpacing.xl)
    }
}
