import SwiftUI

// MARK: - In a community's feed

/// A listing inside its post (PostCard shows the photos and description
/// above): price, title, condition, where, then "Message seller" for buyers,
/// or the seller's own tools (sold, re-up, …) for the owner. A tap on the
/// details below the photos opens the item page in a pop-up (each item's
/// photos up close); a tap above them opens it as a normal post.
struct ListingPostCard: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: ListingViewModel
    @State private var chatId: String?
    @State private var pickItem = false
    @State private var showDetail = false
    /// The post photo on screen; with several items, photo N is item N's cover.
    let photoIndex: Int
    /// The community feed it's shown in, if any: the seller page lists their
    /// items there first.
    let communityId: String?

    init(post: Post, photoIndex: Int = 0, communityId: String? = nil) {
        _viewModel = State(initialValue: ListingViewModel(post: post))
        self.photoIndex = photoIndex
        self.communityId = communityId
    }

    var body: some View {
        if let listing = viewModel.listing {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    ListingSummary(listing: listing)
                    if listing.hasSeveralItems {
                        ListingItemLines(listing: listing, highlightedId: listing.displayItems[safeIndex: photoIndex]?.id)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showDetail = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Opens the item page", bundle: bundle))

                if viewModel.isSeller(appState.currentUser?.id) {
                    ListingSellerBar(viewModel: viewModel, showsShare: false)
                } else if !listing.isSold && !(appState.currentUser?.isOfficial ?? false) {
                    Button {
                        if listing.hasSeveralItems { pickItem = true } else { message(about: nil) }
                    } label: {
                        Label(bundle.loc("Message seller"), systemImage: "message.fill")
                            .scaledFont(14, .semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isOpeningChat || !listing.canAskAnyItem)
                    .listingItemPicker(isPresented: $pickItem, listing: listing) { message(about: $0) }
                }
                if let error = viewModel.errorMessage {
                    Text(error).scaledFont(12).foregroundColor(AppColors.danger(colorScheme))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .listingChat(conversationId: $chatId, seller: viewModel.post.author)
            // Full height: the item photos are what the buyer came to look at;
            // swipe down to close.
            .sheet(isPresented: $showDetail) {
                NavigationStack {
                    ListingDetailView(post: viewModel.post, communityId: communityId)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { showDetail = false } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel(Text("Close", bundle: bundle))
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .environment(appState)
                .environment(themeManager)
            }
        }
    }

    private func message(about item: ListingItem?) {
        Task<Void, Never>(name: nil) { chatId = await viewModel.messageSeller(item: item, token: appState.authToken ?? "") }
    }
}

/// A listing of several items in the feed: one line per item under the
/// seller's own caption, the first 5, then "See more" opens the box to all.
struct ListingItemLines: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let listing: ListingData
    /// The item whose photo is on screen in the post above.
    var highlightedId: String? = nil
    private let shown = 5
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { item in
                let on = item.id == highlightedId
                HStack(spacing: 8) {
                    // A long name ends in "…"; the price always keeps its room.
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(item.isSold)
                        .fontWeight(on ? .semibold : .regular)
                        .foregroundColor(item.isSold ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if item.isSold {
                            SoldBadge()
                        } else {
                            HStack(spacing: 6) {
                                Text(item.priceText(loc: bundle.loc))
                                    .fontWeight(.semibold)
                                    .foregroundColor(on ? themeManager.theme.primary : AppColors.textPrimary(colorScheme))
                                Text(String(format: bundle.loc("Qty %lld"), item.remaining))
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                        }
                    }
                    .fixedSize()
                    .layoutPriority(1)
                }
                .scaledFont(14)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(on ? themeManager.theme.primary.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            // A button, so it opens the box instead of the item pop-up around it.
            if listing.items.count > shown && !expanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
                } label: {
                    Text(String(format: bundle.loc("See more (%lld)"), listing.items.count - shown))
                        .scaledFont(13, .semibold)
                        .foregroundColor(themeManager.theme.primary)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: highlightedId)
    }

    /// The lines shown: all once opened; otherwise the first 5, plus the item
    /// whose photo is on screen when it's further down, so its highlight shows.
    private var rows: [ListingItem] {
        let all = listing.displayItems
        guard !expanded else { return all }
        var first = Array(all.prefix(shown))
        if let id = highlightedId, !first.contains(where: { $0.id == id }),
           let item = all.first(where: { $0.id == id }) {
            first.append(item)
        }
        return first
    }
}

extension Array {
    /// The element at `index`, or nil when it's out of range.
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct ListingItemPicker: ViewModifier {
    @Environment(\.appBundle) private var bundle
    @Binding var isPresented: Bool
    let listing: ListingData
    let onPick: (ListingItem) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(bundle.loc("Which item are you asking about?"), isPresented: $isPresented,
                                   titleVisibility: .visible) {
            // Items asked about in the last 20 minutes aren't offered again yet.
            ForEach(listing.availableItems.filter { $0.canAsk() }) { item in
                Button(item.title + " · " + item.priceText(loc: bundle.loc)) { onPick(item) }
            }
        }
    }
}

private extension View {
    /// "Message seller" on a listing of several items asks which one first.
    func listingItemPicker(isPresented: Binding<Bool>, listing: ListingData,
                           onPick: @escaping (ListingItem) -> Void) -> some View {
        modifier(ListingItemPicker(isPresented: isPresented, listing: listing, onPick: onPick))
    }
}

extension ListingData {
    /// "Message seller" on a listing of several asks which item; it's off while
    /// every unsold item was asked about in the last 20 minutes.
    var canAskAnyItem: Bool { !hasSeveralItems || availableItems.contains { $0.canAsk() } }
}

/// "7 items" or "4 of 7 left" on a listing of several.
enum ListingItemCount {
    static func text(_ listing: ListingData, bundle: Bundle) -> String {
        let left = listing.availableItems.count
        return left == listing.items.count || left == 0
            ? String(format: bundle.loc("%lld items"), listing.items.count)
            : String(format: bundle.loc("%lld of %lld left"), left, listing.items.count)
    }
}

/// "7 items" on a Marketplace card. Text only, styled like `ReupBadge`, so the
/// pills beside each other are the same height.
struct ItemCountBadge: View {
    let text: String
    var body: some View { ReupBadge(text: text) }
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
                Text(listing.fromPriceText(bundle: bundle))
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
                if listing.hasSeveralItems {
                    Text(ListingItemCount.text(listing, bundle: bundle))
                } else {
                    Text(bundle.loc(listing.condition.label))
                    if let item = listing.items.first, !item.isSold {
                        Text("·")
                        Text(String(format: bundle.loc("Qty %lld"), item.remaining))
                        if item.onHold > 0 {
                            Text("·")
                            Text(String(format: bundle.loc("%lld on hold"), item.onHold))
                        }
                    }
                }
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
                ListingPhotoCarousel(urls: post.displayImageUrls, cornerRadius: 10, expandsOnTap: false,
                                     tags: post.listingData?.photoTags(count: post.displayImageUrls.count, loc: bundle.loc))
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
                Text(listing.fromPriceText(bundle: bundle))
                    .scaledFont(15, .bold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                // The badge row is always there, empty when there's nothing to
                // show: a card without it would be shorter than its neighbour.
                HStack(spacing: 6) {
                    if listing.isSold { SoldBadge() }
                    // Once everything is sold, only "Sold" and the re-up count matter.
                    if listing.hasSeveralItems && !listing.isSold {
                        ItemCountBadge(text: ListingItemCount.text(listing, bundle: bundle))
                    }
                    if let text = listing.reupText(bundle: bundle) { ReupBadge(text: text) }
                    // Only the seller's own items carry a schedule.
                    if listing.autoReup != nil && !listing.isSold {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .scaledFont(11, .bold)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .accessibilityLabel(Text("Auto re-up", bundle: bundle))
                    }
                    if !listing.isSold && !listing.hasSeveralItems && listing.reupCount == 0 && listing.autoReup == nil {
                        ReupBadge(text: " ").hidden().accessibilityHidden(true)
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
    @State private var pickItem = false
    /// The seller's Deposit / Mark as sold sheet for one item.
    @State private var buyerSheet: ListingBuyerRoute?
    /// The item a buyer tapped "Ask about this" on, waiting for them to confirm.
    @State private var itemToAsk: ListingItem?

    /// The community it was opened from, if any (see `sellerCommunities`).
    private let communityId: String?

    init(post: Post, communityId: String? = nil) {
        _viewModel = State(initialValue: ListingViewModel(post: post))
        self.communityId = communityId
    }

    /// Where the seller page looks first for their other items: the community
    /// this was opened from, else every community it's listed in.
    private var sellerCommunities: [ListingData.ListedIn] {
        let posted = viewModel.listing?.postedCommunities ?? []
        if let communityId, let here = posted.first(where: { $0.id == communityId }) { return [here] }
        return posted
    }

    private var isSeller: Bool { viewModel.isSeller(appState.currentUser?.id) }

    /// "Marketplace", or the communities it also shows in.
    private var listedIn: String {
        let names = viewModel.listing?.postedCommunities.map(\.name) ?? []
        return names.isEmpty ? bundle.loc("Marketplace") : names.joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !viewModel.post.displayImageUrls.isEmpty {
                    ListingPhotoCarousel(urls: viewModel.post.displayImageUrls, aspectRatio: 4.0 / 3.0, cornerRadius: 0,
                                         tags: viewModel.listing?.photoTags(count: viewModel.post.displayImageUrls.count,
                                                                            loc: bundle.loc))
                }
                if let listing = viewModel.listing {
                    VStack(alignment: .leading, spacing: 4) {
                        ListingSummary(listing: listing, large: true)
                        Text(viewModel.post.timestamp.timeAgoString)
                            .scaledFont(13)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
                // The seller's own words come first, as they wrote them; the
                // items and the map follow.
                description
                if let listing = viewModel.listing {
                    if listing.hasSeveralItems {
                        itemList(listing).padding(.horizontal, AppSpacing.lg)
                    }
                    if let lat = listing.latitude, let lng = listing.longitude {
                        ListingMapPreview(latitude: lat, longitude: lng, name: listing.location ?? listing.title)
                            .padding(.horizontal, AppSpacing.lg)
                    }
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
        .sheet(item: $buyerSheet) { route in
            if let listing = viewModel.listing {
                ListingBuyerSheet(mode: route.mode, listing: listing) { viewModel.replacePost($0) }
            }
        }
    }

    /// Everything for sale in a listing of several: each item's own photos
    /// (price-tagged), title, price and condition. The seller marks each sold
    /// on its own; a buyer can ask about one directly.
    private func itemList(_ listing: ListingData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: bundle.loc("Items (%lld)"), listing.items.count))
                .scaledFont(15, .semibold)
            ForEach(listing.displayItems) { item in
                HStack(alignment: .top, spacing: 12) {
                    ListingPhotoCarousel(urls: item.imageUrls, cornerRadius: 10,
                                         tags: item.imageUrls.map { _ in item.photoTag(loc: bundle.loc) })
                        .frame(width: 112)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .scaledFont(15, .semibold)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(item.priceText(loc: bundle.loc))
                                .scaledFont(15, .bold)
                                .strikethrough(item.isSold)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                            if item.isSold {
                                SoldBadge()
                            } else {
                                Text(String(format: bundle.loc("Qty %lld"), item.remaining))
                                    .scaledFont(13, .semibold)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                        }
                        if !item.isSold && item.onHold > 0 {
                            // "Qty N" above already shows what's free, so only the hold is added.
                            Text(String(format: bundle.loc("%lld on hold"), item.onHold))
                                .scaledFont(13)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                        Text(bundle.loc(item.condition.label))
                            .scaledFont(13)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                        itemAction(item)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// The seller's Deposit and Mark as sold (both pick the buyer from their
    /// chats; selling confirms a deposit and sends a review card), or a buyer's
    /// "Ask about this", which asks first in a pop-up on the button itself.
    @ViewBuilder
    private func itemAction(_ item: ListingItem) -> some View {
        if isSeller {
            if !item.isSold {
                HStack(spacing: 16) {
                    Button(bundle.loc("Deposit")) { buyerSheet = .init(mode: .deposit(item)) }
                    Button(bundle.loc("Mark as sold")) { buyerSheet = .init(mode: .confirm(item)) }
                        .disabled(item.deposits.isEmpty)
                }
                .scaledFont(13, .semibold)
                .foregroundColor(themeManager.theme.primary)
                .buttonStyle(.plain)
                .disabled(viewModel.isWorking)
                .padding(.top, 2)
            }
        } else if !item.isSold && !(appState.currentUser?.isOfficial ?? false) {
            // One question per item every 20 minutes: until then the button is
            // off, with the minutes left beside it (re-checked every few seconds).
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let canAsk = item.canAsk(at: context.date)
                HStack(spacing: 8) {
                    Button(bundle.loc("Ask about this")) { itemToAsk = item }
                        .scaledFont(13, .semibold)
                        .foregroundColor(canAsk ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                        .buttonStyle(.plain)
                        .disabled(viewModel.isOpeningChat || !canAsk)
                        .disabledWhenRestricted()
                    if !canAsk {
                        Label(String(format: bundle.loc("%lld min"), item.askWaitMinutes(at: context.date)),
                              systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                            .scaledFont(12, .semibold)
                            .monospacedDigit()
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                            .accessibilityLabel(Text(String(format: bundle.loc("You can ask about this item again in %d minutes"),
                                                            item.askWaitMinutes(at: context.date))))
                    }
                }
            }
            .padding(.top, 2)
            .confirmationDialog(bundle.loc("Ask the seller about this item?"),
                                    isPresented: isShowing($itemToAsk, item), titleVisibility: .visible) {
                    Button(bundle.loc("Send")) { message(about: item) }
                } message: {
                    Text(String(format: bundle.loc("The seller gets: Is “%@” still available?"), item.title))
                }
        }
    }

    /// True while `pending` holds this item; clearing it closes the pop-up.
    private func isShowing(_ pending: Binding<ListingItem?>, _ item: ListingItem) -> Binding<Bool> {
        Binding(get: { pending.wrappedValue?.id == item.id }, set: { if !$0 { pending.wrappedValue = nil } })
    }

    private func message(about item: ListingItem?) {
        Task<Void, Never>(name: nil) { chatId = await viewModel.messageSeller(item: item, token: appState.authToken ?? "") }
    }

    @ViewBuilder
    private var description: some View {
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
                MarketplaceSellerView(seller: viewModel.post.author, mode: viewModel.post.mode,
                                      communities: sellerCommunities)
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
                        Text("This item has been sold", bundle: bundle)
                            .scaledFont(15, .semibold)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        Button {
                            if listing.hasSeveralItems { pickItem = true } else { message(about: nil) }
                        } label: {
                            Label(bundle.loc("Message seller"), systemImage: "message.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ListingButtonStyle(fill: themeManager.theme.primary))
                        .disabled(viewModel.isOpeningChat || !listing.canAskAnyItem)
                        .listingItemPicker(isPresented: $pickItem, listing: listing) { message(about: $0) }
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
/// Which Deposit / Mark as sold sheet the seller opened.
struct ListingBuyerRoute: Identifiable {
    let id = UUID()
    let mode: ListingBuyerViewModel.Mode
}

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
    @State private var confirmReup = false
    @State private var showShare = false
    /// Deposit / Mark as sold: both pick the buyer from the seller's chats.
    @State private var buyerSheet: ListingBuyerRoute?

    var body: some View {
        if let listing = viewModel.listing {
            HStack(spacing: 10) {
                soldButton(listing)
                if !listing.isSold {
                    // Ticks each minute so the countdown and the button free up on time.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let wait = listing.reupWaitText(now: context.date, bundle: bundle)
                        Button { confirmReup = true } label: {
                            Text(wait ?? bundle.loc("Re-up"))
                                .scaledFont(15, .semibold)
                                .foregroundColor(wait == nil ? AppColors.textPrimary(colorScheme) : AppColors.textSecondary(colorScheme))
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isWorking || wait != nil)
                    }
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
                        if !listing.hasSeveralItems, let item = listing.items.first, !item.isSold {
                            Button(bundle.loc("Deposit")) { buyerSheet = .init(mode: .deposit(item)) }
                        }
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
                EditListingSheet(listing: listing, mode: viewModel.post.mode, description: viewModel.post.content) { fields in
                    await viewModel.save(fields, token: appState.authToken ?? "")
                }
            }
            .sheet(item: $buyerSheet) { route in
                ListingBuyerSheet(mode: route.mode, listing: listing) { viewModel.replacePost($0) }
            }
            .sheet(isPresented: $showShare) {
                SharePostSheet(post: viewModel.post)
                    .environment(appState)
                    .environment(themeManager)
            }
        }
    }

    /// Mark as sold: confirms a buyer's deposit (on every item of theirs, with
    /// several) and sends them a review card. Sales are final, so a sold
    /// listing has nothing to undo.
    @ViewBuilder
    private func soldButton(_ listing: ListingData) -> some View {
        let item = listing.hasSeveralItems ? nil : listing.items.first
        let label: String = listing.isSold ? bundle.loc("Sold")
            : listing.hasSeveralItems ? bundle.loc("Mark all as sold")
            : item.map { $0.quantity > 1
                ? String(format: bundle.loc("%lld sold · %lld left"), $0.soldCount, $0.left)
                : bundle.loc("Mark as sold") } ?? bundle.loc("Mark as sold")
        let hasDeposits = (item.map { [$0] } ?? listing.items).contains { !$0.deposits.isEmpty }
        Button {
            buyerSheet = .init(mode: item.map { .confirm($0) } ?? .confirmAll)
        } label: {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(ListingButtonStyle(fill: themeManager.theme.primary.opacity(hasDeposits ? 1 : 0.45)))
        .disabled(listing.isSold || !hasDeposits)
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
    @Environment(AppState.self) private var appState

    @State private var viewModel: EditListingViewModel
    @State private var confirmSave = false
    let onSave: ([String: Any]) async -> Bool

    init(listing: ListingData, mode: AppMode, description: String, onSave: @escaping ([String: Any]) async -> Bool) {
        _viewModel = State(initialValue: EditListingViewModel(listing: listing, mode: mode, description: description))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                ListingItemsSection(items: viewModel.items, headline: $viewModel.headline, description: $viewModel.details)
                Section {
                    ListingLocationRow(place: $viewModel.place)
                }
                communitiesSection
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
                    Button(bundle.loc("Save")) { confirmSave = true }
                        .disabled(!viewModel.isValid || viewModel.isSaving)
                        .confirmationDialog(bundle.loc("Save changes to this listing?"),
                                            isPresented: $confirmSave, titleVisibility: .visible) {
                            Button(bundle.loc("Save")) {
                                Task<Void, Never>(name: nil) {
                                    guard let fields = await viewModel.fields() else { return }
                                    if await onSave(fields) { dismiss() }
                                }
                            }
                            Button(bundle.loc("Cancel"), role: .cancel) {}
                        }
                }
            }
            .task { await viewModel.loadCommunities(token: appState.authToken ?? "") }
        }
    }

    /// Tick to also list it in a community, untick to take it out of one.
    private var communitiesSection: some View {
        Section {
            if viewModel.isLoadingCommunities {
                ProgressView().frame(maxWidth: .infinity)
            } else if viewModel.communityChoices.isEmpty {
                Text("You haven't joined any communities in this mode.", bundle: bundle)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            ListingCommunityList(
                options: viewModel.communityChoices.map { .init(id: $0.id, name: $0.name, note: viewModel.note(for: $0)) },
                isSelected: viewModel.isSelected, isFull: viewModel.isCommunitiesFull, toggle: viewModel.toggleCommunity)
        } header: {
            HStack {
                Text("Also list in", bundle: bundle)
                Spacer()
                Text(String(format: bundle.loc("%lld/%lld selected"), viewModel.selectedCommunities.count,
                            CreateListingViewModel.maxCommunities))
            }
        } footer: {
            Text("Untick a community to take the listing out of it.", bundle: bundle)
        }
    }
}
