import SwiftUI

// MARK: - Environment
/// Opens the rating sheet for a legit card from the chat screen itself. The
/// card sits in the chat's lazy message list, which re-lays out (and can
/// rebuild the card) when the keyboard comes up; a sheet presented from the
/// card was torn down with it, so the comment field kept losing focus.
private struct RateLegitCardKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

/// Opens a seller's Marketplace page (by user id) from the chat screen, for
/// the same reason as `rateLegitCard`.
private struct OpenLegitSellerKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var rateLegitCard: ((String) -> Void)? {
        get { self[RateLegitCardKey.self] }
        set { self[RateLegitCardKey.self] = newValue }
    }
    var openLegitSeller: ((String) -> Void)? {
        get { self[OpenLegitSellerKey.self] }
        set { self[OpenLegitSellerKey.self] = newValue }
    }
}

// MARK: - Chat legit card
/// A review (legit) card in a chat. The buyer taps it to rate the seller (once, within
/// 3 days); the seller sees whether it's been used.
struct ChatLegitCard: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rateLegitCard) private var rateLegitCard
    @Environment(\.openLegitSeller) private var openLegitSeller

    let inviteId: String
    @State private var viewModel = ChatLegitCardViewModel()
    @State private var reviewing = false

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        Group {
            if let card = viewModel.card {
                content(card)
            } else if viewModel.unavailable {
                Text("This review card isn't available", bundle: bundle)
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(12)
                    .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView().frame(width: 220, height: 80)
            }
        }
        .frame(maxWidth: 260)
        .task { await viewModel.load(id: inviteId, token: token) }
        .onReceive(NotificationCenter.default.publisher(for: .legitCardReviewed)) { note in
            guard note.object as? String == inviteId else { return }
            Task { await viewModel.load(id: inviteId, token: token) }
        }
        .sheet(isPresented: $reviewing) { LegitReviewSheet(viewModel: viewModel) }
    }

    private func content(_ card: LegitCard) -> some View {
        let canRate = viewModel.isBuyer(appState.currentUser?.id) && card.state == .open
        // Once reviewed, either side can open the seller's page to see it.
        let opensSeller = card.state == .reviewed && openLegitSeller != nil
        return Button {
            if canRate {
                if let rateLegitCard { rateLegitCard(inviteId) } else { reviewing = true }
            } else if opensSeller {
                openLegitSeller?(card.sellerId)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let url = APIConfig.mediaURL(card.itemImageUrl) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { AppColors.elevated(colorScheme) }
                    }
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    // `clipped` only hides the overflow: a tall photo still took
                    // taps meant for the card above it.
                    .contentShape(Rectangle())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.itemTitle)
                        .scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                    if let price = card.itemPrice {
                        Text(ListingData.priceText(price, loc: bundle.loc)
                             + (card.itemQuantity > 1 ? " " + String(format: bundle.loc("× %lld"), card.itemQuantity) : ""))
                            .scaledFont(15, .bold)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    status(card, canRate: canRate)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppColors.elevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.borderSubtle(colorScheme), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // Not `.disabled`: an expired card should still read clearly.
        .allowsHitTesting(canRate || opensSeller)
    }

    @ViewBuilder
    private func status(_ card: LegitCard, canRate: Bool) -> some View {
        switch card.state {
        case .reviewed:
            HStack(spacing: 6) {
                if let rating = card.rating { StarRow(rating: Double(rating), size: 12) }
                Text("Reviewed", bundle: bundle).scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        case .expired:
            Text("Expired", bundle: bundle).scaledFont(13)
                .foregroundColor(AppColors.textTertiary(colorScheme))
        case .open:
            if canRate {
                Text("Rate this seller", bundle: bundle)
                    .scaledFont(14, .semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 8))
                Text(String(format: bundle.loc("expires %@"),
                            card.expiresAt.formatted(.relative(presentation: .named))))
                    .scaledFont(11)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            } else {
                Text(String(format: bundle.loc("Waiting for their review · expires %@"),
                            card.expiresAt.formatted(.relative(presentation: .named))))
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }
}

// MARK: - Seller page
/// Which card the chat screen is rating, or whose seller page it shows.
struct LegitReviewRoute: Identifiable { let id: String }

/// A seller's Marketplace page, full height, opened from a reviewed card.
struct LegitSellerPage: View {
    let sellerId: String
    @State private var viewModel = LegitSellerPageViewModel()

    var body: some View {
        ProfilePopup {
            if let seller = viewModel.seller {
                MarketplaceSellerView(seller: seller, mode: .hobby)
            } else if viewModel.failed {
                ContentUnavailableView(Bundle.app.loc("This profile isn't available"), systemImage: "person.slash")
            } else {
                ProgressView()
            }
        }
        .task { await viewModel.load(sellerId: sellerId) }
    }
}

// MARK: - Review screen
/// The rating sheet as the chat screen presents it: loads the card itself.
struct LegitReviewScreen: View {
    @Environment(AppState.self) private var appState
    let inviteId: String
    @State private var viewModel = ChatLegitCardViewModel()

    var body: some View {
        LegitReviewSheet(viewModel: viewModel)
            .task { await viewModel.load(id: inviteId, token: appState.authToken ?? "") }
    }
}

// MARK: - Review sheet
/// The buyer's review: 0–5 stars and a few words, posted on the seller's
/// check-legit post.
struct LegitReviewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ChatLegitCardViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    // Tapping the only lit star again goes down to 0.
                                    viewModel.rating = (viewModel.rating == 1 && star == 1) ? 0 : star
                                } label: {
                                    Image(systemName: star <= viewModel.rating ? "star.fill" : "star")
                                        .font(.system(size: 30))
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(String(format: bundle.loc("%lld of 5 stars"), star)))
                            }
                        }
                        Text(String(format: bundle.loc("%lld of 5 stars"), viewModel.rating))
                            .scaledFont(13)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } header: {
                    Text(viewModel.card?.itemTitle ?? "")
                }
                Section {
                    TextField(bundle.loc("How did it go?"), text: $viewModel.comment, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("Your review shows on the seller's reviews post. You can only send one with this card.",
                         bundle: bundle)
                }
                if let error = viewModel.errorMessage {
                    Text(error).foregroundColor(AppColors.danger(colorScheme))
                }
            }
            .navigationTitle(Text("Rate this seller", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Send")) {
                        Task { if await viewModel.submit(token: appState.authToken ?? "") { dismiss() } }
                    }
                    .disabled(!viewModel.canSubmit)
                }
            }
        }
        // Full height: at half height the keyboard and the sheet's own resize
        // fought over the comment field, so it kept jumping out from the tap.
        .presentationDetents([.large])
    }
}
