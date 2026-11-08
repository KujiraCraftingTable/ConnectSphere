import SwiftUI

// MARK: - In a community's feed

/// A listing inside its post (PostCard shows the photos and description
/// above): price, title, condition, where, then "Message seller" for buyers,
/// or the seller's own tools (sold, re-up, …) for the owner. A tap anywhere
/// else opens it as a normal post.
struct ListingPostCard: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: ListingViewModel
    @State private var chatId: String?

    init(post: Post) { _viewModel = State(initialValue: ListingViewModel(post: post)) }

    var body: some View {
        if let listing = viewModel.listing {
            VStack(alignment: .leading, spacing: 8) {
                ListingSummary(listing: listing)

                if viewModel.isSeller(appState.currentUser?.id) {
                    ListingSellerBar(viewModel: viewModel, showsShare: false)
                } else if !listing.isSold && !(appState.currentUser?.isOfficial ?? false) {
                    Button {
                        Task<Void, Never>(name: nil) { chatId = await viewModel.messageSeller(token: appState.authToken ?? "") }
                    } label: {
                        Label(bundle.loc("Message seller"), systemImage: "message.fill")
                            .scaledFont(14, .semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isOpeningChat)
                }
                if let error = viewModel.errorMessage {
                    Text(error).scaledFont(12).foregroundColor(AppColors.danger(colorScheme))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .listingChat(conversationId: $chatId, seller: viewModel.post.author)
        }
    }
}

/// Price, title, condition and place. Shared by the feed card and the page.
struct ListingSummary: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let listing: ListingData
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(listing.priceText(loc: bundle.loc))
                    .font(.system(size: large ? 24 : 18, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if listing.isSold { SoldBadge() }
                if let text = listing.reupText(bundle: bundle) { ReupBadge(text: text) }
            }
            Text(listing.title)
                .font(.system(size: large ? 18 : 15, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(bundle.loc(listing.condition.label))
                if let location = listing.location {
                    Text("·")
                    Label(location, systemImage: "mappin.and.ellipse").labelStyle(.titleAndIcon)
                }
            }
            .scaledFont(13)
            .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SoldBadge: View {
    @Environment(\.appBundle) private var bundle
    var body: some View {
        Text(bundle.loc("Sold"))
            .scaledFont(11, .bold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.gray, in: Capsule())
    }
}

/// "1st re-up", "2nd re-up"… on an item the seller posted again.
struct ReupBadge: View {
    @Environment(ThemeManager.self) private var themeManager
    let text: String
    var body: some View {
        Text(text)
            .scaledFont(11, .bold)
            .foregroundColor(themeManager.theme.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(themeManager.theme.primary.opacity(0.14), in: Capsule())
    }
}

// MARK: - Marketplace grid

/// A listing in the Marketplace grid: its first photo, price, title, place.
struct ListingCard: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let post: Post

    var body: some View {
        // A tap anywhere on the card opens the item; the photos still swipe.
        NavigationLink { ListingDetailView(post: post) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ListingPhotoCarousel(urls: post.displayImageUrls, cornerRadius: 10, expandsOnTap: false)
                info
            }
            .padding(8)
            .cardStyle()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var info: some View {
        if let listing = post.listingData {
            VStack(alignment: .leading, spacing: 3) {
                Text(listing.priceText(loc: bundle.loc))
                    .scaledFont(15, .bold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if listing.isSold || listing.reupCount > 0 || listing.autoReup != nil {
                    HStack(spacing: 6) {
                        if listing.isSold { SoldBadge() }
                        if let text = listing.reupText(bundle: bundle) { ReupBadge(text: text) }
                        // Only the seller's own items carry a schedule.
                        if listing.autoReup != nil {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .scaledFont(11, .bold)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .accessibilityLabel(Text("Auto re-up", bundle: bundle))
                        }
                    }
                }
                // One line, "…" when longer, so every card is the same height.
                Text(listing.title)
                    .scaledFont(14)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text([post.timestamp.timeAgoString, listing.location].compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(12)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - A listing's page

struct ListingDetailView: View {
    @Environment(\.openURL) private var openURL
    @State private var inAppBrowserURL: URL?
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ListingViewModel
    @State private var chatId: String?
    @State private var showReport = false
    @State private var showShare = false
    @State private var showModerate = false
    @State private var showSeller = false
    @State private var confirmCancelAuto = false

    init(post: Post) { _viewModel = State(initialValue: ListingViewModel(post: post)) }

    private var isSeller: Bool { viewModel.isSeller(appState.currentUser?.id) }

    /// "Marketplace", or the communities it also shows in.
    private var listedIn: String {
        let names = viewModel.listing?.communities.map(\.name) ?? []
        return names.isEmpty ? bundle.loc("Marketplace") : names.joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !viewModel.post.displayImageUrls.isEmpty {
                    ListingPhotoCarousel(urls: viewModel.post.displayImageUrls, aspectRatio: 4.0 / 3.0, cornerRadius: 0)
                }
                if let listing = viewModel.listing {
                    VStack(alignment: .leading, spacing: 4) {
                        ListingSummary(listing: listing, large: true)
                        Text(viewModel.post.timestamp.timeAgoString)
                            .scaledFont(13)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    if let lat = listing.latitude, let lng = listing.longitude {
                        ListingMapPreview(latitude: lat, longitude: lng, name: listing.location ?? listing.title)
                            .padding(.horizontal, AppSpacing.lg)
                    }
                }
                if !viewModel.post.content.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description", bundle: bundle)
                            .scaledFont(15, .semibold)
                        Text(viewModel.post.isMarkdown
                             ? MarkdownFormatter.attributed(viewModel.post.content, linkColor: themeManager.theme.primary,
                                                            quoteColor: AppColors.textSecondary(colorScheme))
                             : AttributedString(viewModel.post.content))
                            .scaledFont(15)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .environment(\.openURL, OpenURLAction { url in
                                if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                                    inAppBrowserURL = url
                                } else {
                                    openURL(url)
                                }
                                return .handled
                            })
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
                if isSeller, let listing = viewModel.listing, !listing.isSold, listing.autoReup != nil {
                    autoReupRow(listing).padding(.horizontal, AppSpacing.lg)
                }
                sellerRow
                    .padding(.horizontal, AppSpacing.lg)
                if let error = viewModel.errorMessage {
                    Text(error).scaledFont(13).foregroundColor(AppColors.danger(colorScheme))
                        .padding(.horizontal, AppSpacing.lg)
                }
            }
            .padding(.bottom, AppSpacing.lg)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        // The item page has its own action bar; the tab bar would sit under it.
        .toolbar(.hidden, for: .tabBar)
        .inAppBrowser(url: $inAppBrowserURL)
        .safeAreaInset(edge: .bottom) { actionBar }
        .listingChat(conversationId: $chatId, seller: viewModel.post.author)
    }

    /// The seller's auto re-up schedule, with the next run and a way to stop it.
    private func autoReupRow(_ listing: ListingData) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(themeManager.theme.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.autoReupText(bundle: bundle) ?? "")
                    .scaledFont(14, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if let next = listing.nextAutoReupText(bundle: bundle) {
                    Text(next).scaledFont(12).foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            Spacer()
            Button(bundle.loc("Cancel")) { confirmCancelAuto = true }
                .scaledFont(14, .semibold)
                .foregroundColor(AppColors.danger(colorScheme))
                .buttonStyle(.plain)
                .confirmationDialog(bundle.loc("Stop auto re-up?"), isPresented: $confirmCancelAuto, titleVisibility: .visible) {
                    Button(bundle.loc("Stop auto re-up"), role: .destructive) {
                        Task<Void, Never>(name: nil) { await viewModel.cancelAutoReup(token: appState.authToken ?? "") }
                    }
                } message: {
                    Text(bundle.loc("The item stays listed; you can turn it on again from Edit listing."))
                }
        }
        .padding(12)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Tapping the seller opens their Marketplace profile (their other items)
    /// as a pop-up over the item.
    private var sellerRow: some View {
        Button { showSeller = true } label: {
            HStack(spacing: 10) {
                AvatarView(user: viewModel.post.author, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.post.author.name)
                        .scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Text(String(format: bundle.loc("Listed in %@"), listedIn))
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(13, .semibold)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            .padding(12)
            .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSeller) {
            ProfilePopup {
                MarketplaceSellerView(seller: viewModel.post.author, mode: viewModel.post.mode, excluding: viewModel.post.id)
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if let listing = viewModel.listing {
            HStack(spacing: 10) {
                if isSeller {
                    ListingSellerBar(viewModel: viewModel) { dismiss() }
                } else if appState.currentUser?.isOfficial ?? false {
                    // The admin only monitors the Marketplace: no buying, saving,
                    // sharing or reporting. Warn or ban also takes the item down.
                    Button { showModerate = true } label: {
                        Label(bundle.loc("Warn or ban"), systemImage: "hand.raised.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ListingButtonStyle(fill: AppColors.danger(colorScheme)))
                    .sheet(isPresented: $showModerate, onDismiss: {
                        if viewModel.wasTakenDown() { dismiss() }
                    }) {
                        AdminBanSheet(target: ModerationTarget(type: "post", id: viewModel.post.id,
                                                               userId: viewModel.post.author.id,
                                                               userName: viewModel.post.author.name,
                                                               mode: viewModel.post.mode.rawValue))
                            .environment(themeManager)
                    }
                } else {
                    if listing.isSold {
                        Label(bundle.loc("This item has been sold"), systemImage: "checkmark.seal")
                            .scaledFont(15, .semibold)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        Button {
                            Task<Void, Never>(name: nil) { chatId = await viewModel.messageSeller(token: appState.authToken ?? "") }
                        } label: {
                            Label(bundle.loc("Message seller"), systemImage: "message.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ListingButtonStyle(fill: themeManager.theme.primary))
                        .disabled(viewModel.isOpeningChat)
                    }
                    squareButton(viewModel.isSaved ? "bookmark.fill" : "bookmark",
                                 label: viewModel.isSaved ? "Unsave" : "Save",
                                 tint: viewModel.isSaved ? themeManager.theme.primary : nil) {
                        Task<Void, Never>(name: nil) { await viewModel.toggleSave() }
                    }
                    squareButton("square.and.arrow.up", label: "Share") { showShare = true }
                    squareButton("flag", label: "Report") { showReport = true }
                        .sheet(isPresented: $showReport) {
                            // A listing is reported as the post it lives in.
                            // The listing stays open after a report, like any post.
                            ReportSheet(subject: .content(.post, id: viewModel.post.id),
                                        blockUser: (viewModel.post.author.id, viewModel.post.author.name))
                                .environment(themeManager)
                        }
                }
            }
            .disabled(viewModel.isWorking)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, 10)
            .background(.bar)
            .sheet(isPresented: $showShare) {
                SharePostSheet(post: viewModel.post)
                    .environment(appState)
                    .environment(themeManager)
            }
        }
    }

    private func squareButton(_ systemImage: String, label: String, tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        ListingSquareButton(systemImage: systemImage, label: label, tint: tint, action: action)
    }
}

/// A small square icon button beside a listing bar's main button.
private struct ListingSquareButton: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let label: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(17, .semibold)
                .foregroundColor(tint ?? AppColors.textPrimary(colorScheme))
                .frame(width: 46, height: 44)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(bundle.loc(label)))
    }
}

/// The seller's tools for one of their items, Mark as sold, Re-up, and "…"
/// (edit, share, delete). Shared by the item page and the post card.
struct ListingSellerBar: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let viewModel: ListingViewModel
    /// The post card has its own share button, so it leaves Share out of "…";
    /// the item page has none, so it keeps it (until the item is sold).
    var showsShare = true
    /// Called after the seller deletes the item (the item page closes itself).
    var onDeleted: () -> Void = {}

    @State private var showEdit = false
    @State private var showActions = false
    @State private var confirmDelete = false
    @State private var confirmSoldChange = false
    @State private var confirmReup = false
    @State private var showShare = false

    var body: some View {
        if let listing = viewModel.listing {
            HStack(spacing: 10) {
                Button { confirmSoldChange = true } label: {
                    Text(bundle.loc(listing.isSold ? "Mark as available" : "Mark as sold"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ListingButtonStyle(fill: themeManager.theme.primary))
                .confirmationDialog(bundle.loc(listing.isSold ? "Mark this item as available?" : "Mark this item as sold?"),
                                    isPresented: $confirmSoldChange, titleVisibility: .visible) {
                    Button(bundle.loc(listing.isSold ? "Mark as available" : "Mark as sold")) {
                        Task<Void, Never>(name: nil) { await viewModel.setSold(!listing.isSold, token: appState.authToken ?? "") }
                    }
                } message: {
                    Text(bundle.loc(listing.isSold ? "Buyers will be able to message you about it again."
                                    : listing.autoReup != nil
                                    ? "Buyers won't be able to message you about it anymore. Auto re-up will be turned off."
                                    : "Buyers won't be able to message you about it anymore."))
                }
                if !listing.isSold {
                    Button { confirmReup = true } label: {
                        Text(bundle.loc("Re-up"))
                            .scaledFont(15, .semibold)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isWorking)
                    .confirmationDialog(bundle.loc("Post this item again as new?"),
                                        isPresented: $confirmReup, titleVisibility: .visible) {
                        Button(bundle.loc("Re-up")) {
                            Task<Void, Never>(name: nil) { await viewModel.reup(token: appState.authToken ?? "") }
                        }
                    } message: {
                        Text(bundle.loc("It appears as a new post in the communities it was listed in, and the earlier post is hidden. Likes and comments don't carry over."))
                    }
                }
                // A plain button + action sheet: on iOS 26 a Menu in this bar
                // didn't present the edit sheet from its action.
                ListingSquareButton(systemImage: "ellipsis", label: "More") { showActions = true }
                    // On the button itself so the pop-up points at it, not the page.
                    .confirmationDialog("", isPresented: $showActions) {
                        Button(bundle.loc("Edit listing")) { showEdit = true }
                        if showsShare && !listing.isSold { Button(bundle.loc("Share")) { showShare = true } }
                        Button(bundle.loc("Delete"), role: .destructive) { confirmDelete = true }
                    }
                    .confirmationDialog(bundle.loc("Delete this listing?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(bundle.loc("Delete"), role: .destructive) {
                            Task<Void, Never>(name: nil) { if await viewModel.delete() { onDeleted() } }
                        }
                    }
            }
            .disabled(viewModel.isWorking)
            .sheet(isPresented: $showEdit) {
                EditListingSheet(post: viewModel.post, listing: listing) { fields in
                    await viewModel.save(fields, token: appState.authToken ?? "")
                }
            }
            .sheet(isPresented: $showShare) {
                SharePostSheet(post: viewModel.post)
                    .environment(appState)
                    .environment(themeManager)
            }
        }
    }
}

private struct ListingButtonStyle: ButtonStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(15, .semibold)
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Opening the chat

private struct ListingChat: ViewModifier {
    @Environment(AppState.self) private var appState
    @Binding var conversationId: String?
    let seller: UserProfile

    func body(content: Content) -> some View {
        content.navigationDestination(isPresented: Binding(
            get: { conversationId != nil }, set: { if !$0 { conversationId = nil } })) {
            if let conversationId {
                ChatView(
                    conversationId: conversationId,
                    peer: .direct(otherUserId: seller.id, name: seller.name,
                                  avatarColor: seller.avatarColor, avatarUrl: seller.avatarUrl),
                    otherUserLocation: seller.location,
                    currentUserId: appState.currentUser?.id ?? "",
                    token: appState.authToken ?? ""
                )
            }
        }
    }
}

private extension View {
    /// Pushes the chat with the seller once "Message seller" has opened it.
    func listingChat(conversationId: Binding<String?>, seller: UserProfile) -> some View {
        modifier(ListingChat(conversationId: conversationId, seller: seller))
    }
}

// MARK: - The seller's edits

struct EditListingSheet: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EditListingViewModel
    let onSave: ([String: Any]) async -> Bool

    init(post: Post, listing: ListingData, onSave: @escaping ([String: Any]) async -> Bool) {
        _viewModel = State(initialValue: EditListingViewModel(post: post, listing: listing))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                ListingPhotosSection(photos: viewModel.photos)
                Section {
                    TextField(bundle.loc("Title"), text: $viewModel.title)
                    ListingPriceField(placeholder: bundle.loc("Price"), text: $viewModel.price)
                    Picker(bundle.loc("Condition"), selection: $viewModel.condition) {
                        ForEach(ListingCondition.allCases, id: \.self) { Text(bundle.loc($0.label)).tag($0) }
                    }
                    ListingLocationRow(place: $viewModel.place)
                }
                Section {
                    Toggle(bundle.loc("Auto-reply"), isOn: $viewModel.autoReplyOn)
                    if viewModel.autoReplyOn {
                        TextField(bundle.loc("Your reply"), text: $viewModel.autoReply, axis: .vertical).lineLimit(2...4)
                    }
                } footer: {
                    Text("Sent once to each buyer who messages you about this listing.", bundle: bundle)
                }
                Section {
                    Toggle(bundle.loc("Hide from friends"), isOn: $viewModel.hideFromFriends)
                } footer: {
                    Text("Your connections won't see this listing.", bundle: bundle)
                }
                AutoReupSection(isOn: $viewModel.autoReupOn, days: $viewModel.autoReupDays, hour: $viewModel.autoReupHour)
                if let error = viewModel.errorMessage {
                    Text(error).foregroundColor(AppColors.danger(colorScheme))
                }
            }
            .tint(themeManager.theme.primary)
            .navigationTitle(Text("Edit listing", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ConfirmCancelButton(hasChanges: viewModel.hasChanges) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Save")) {
                        Task<Void, Never>(name: nil) {
                            guard let fields = await viewModel.fields() else { return }
                            if await onSave(fields) { dismiss() }
                        }
                    }
                    .disabled(!viewModel.isValid || viewModel.isSaving)
                }
            }
        }
    }
}
