import SwiftUI

// MARK: - In a community's feed

/// A listing inside its post (PostCard shows the photos and description
/// above): price, title, condition, where, and "Message seller".
struct ListingPostCard: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: ListingViewModel
    @State private var chatId: String?
    @State private var showDetail = false

    init(post: Post) { _viewModel = State(initialValue: ListingViewModel(post: post)) }

    var body: some View {
        if let listing = viewModel.listing {
            VStack(alignment: .leading, spacing: 8) {
                // The item's Marketplace page, as a pop-up over the feed.
                Button { showDetail = true } label: {
                    ListingSummary(listing: listing)
                }
                .buttonStyle(.plain)

                if !viewModel.isSeller(appState.currentUser?.id) && !listing.isSold {
                    Button {
                        Task<Void, Never>(name: nil) { chatId = await viewModel.messageSeller(token: appState.authToken ?? "") }
                    } label: {
                        Label(bundle.loc("Message seller"), systemImage: "message.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(themeManager.theme.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isOpeningChat)
                }
                if let error = viewModel.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundColor(AppColors.danger(colorScheme))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .listingChat(conversationId: $chatId, seller: viewModel.post.author)
            .sheet(isPresented: $showDetail) {
                NavigationStack {
                    ListingDetailView(post: viewModel.post)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { showDetail = false } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel(Text("Close", bundle: bundle))
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(appState)
                .environment(themeManager)
            }
        }
    }
}

/// Price, title, condition and place — shared by the feed card and the page.
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
            .font(.system(size: 13))
            .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SoldBadge: View {
    @Environment(\.appBundle) private var bundle
    var body: some View {
        Text(bundle.loc("Sold"))
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.gray, in: Capsule())
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                // One line, "…" when longer, so every card is the same height.
                Text(listing.title)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text([post.timestamp.timeAgoString, listing.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - A listing's page

struct ListingDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ListingViewModel
    @State private var chatId: String?
    @State private var showEdit = false
    @State private var showActions = false
    @State private var confirmDelete = false
    @State private var confirmSoldChange = false
    @State private var showShare = false
    @State private var showSeller = false

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
                            .font(.system(size: 13))
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
                            .font(.system(size: 15, weight: .semibold))
                        Text(viewModel.post.content)
                            .font(.system(size: 15))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
                sellerRow
                    .padding(.horizontal, AppSpacing.lg)
                if let error = viewModel.errorMessage {
                    Text(error).font(.system(size: 13)).foregroundColor(AppColors.danger(colorScheme))
                        .padding(.horizontal, AppSpacing.lg)
                }
            }
            .padding(.bottom, AppSpacing.lg)
        }
        .appBackground()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { actionBar }
        .listingChat(conversationId: $chatId, seller: viewModel.post.author)
        .sheet(isPresented: $showEdit) {
            if let listing = viewModel.listing {
                EditListingSheet(listing: listing) { fields in
                    await viewModel.save(fields, token: appState.authToken ?? "")
                }
            }
        }
    }

    /// Tapping the seller opens their Marketplace profile (their other items)
    /// as a pop-up over the item.
    private var sellerRow: some View {
        Button { showSeller = true } label: {
            HStack(spacing: 10) {
                AvatarView(user: viewModel.post.author, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.post.author.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Text(String(format: bundle.loc("Listed in %@"), listedIn))
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
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
                                                       : "Buyers won't be able to message you about it anymore."))
                    }
                    // A plain button + action sheet: on iOS 26 a Menu in this bar
                    // didn't present the edit sheet from its action.
                    squareButton("ellipsis", label: "More") { showActions = true }
                    // On the button itself so the pop-up points at it, not the page.
                    .confirmationDialog("", isPresented: $showActions) {
                        Button(bundle.loc("Edit listing")) { showEdit = true }
                        Button(bundle.loc("Share")) { showShare = true }
                        Button(bundle.loc("Delete"), role: .destructive) { confirmDelete = true }
                    }
                    .confirmationDialog(bundle.loc("Delete this listing?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(bundle.loc("Delete"), role: .destructive) {
                            Task<Void, Never>(name: nil) { if await viewModel.delete() { dismiss() } }
                        }
                    }
                } else {
                    if listing.isSold {
                        Label(bundle.loc("This item has been sold"), systemImage: "checkmark.seal")
                            .font(.system(size: 15, weight: .semibold))
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

    /// A small square icon button beside the bar's main button.
    private func squareButton(_ systemImage: String, label: String, tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint ?? AppColors.textPrimary(colorScheme))
                .frame(width: 46, height: 44)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(bundle.loc(label)))
    }
}

private struct ListingButtonStyle: ButtonStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
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
    @Environment(\.dismiss) private var dismiss

    let listing: ListingData
    let onSave: ([String: Any]) async -> Bool

    @State private var title: String
    @State private var price: String
    @State private var condition: ListingCondition
    @State private var place: PickedPlace?
    @State private var autoReplyOn: Bool
    @State private var autoReply: String
    @State private var hideFromFriends: Bool
    @State private var isSaving = false

    init(listing: ListingData, onSave: @escaping ([String: Any]) async -> Bool) {
        self.listing = listing
        self.onSave = onSave
        _title = State(initialValue: listing.title)
        _price = State(initialValue: listing.price > 0 ? String(listing.price) : "")
        _condition = State(initialValue: listing.condition)
        _place = State(initialValue: listing.latitude.flatMap { lat in
            listing.longitude.map { PickedPlace(name: listing.location ?? listing.title, latitude: lat, longitude: $0) }
        })
        _autoReplyOn = State(initialValue: listing.hasAutoReply)
        _autoReply = State(initialValue: listing.autoReply ?? Bundle.app.loc("Hi! Yes, it's still available."))
        _hideFromFriends = State(initialValue: listing.hideFromFriends)
    }

    private var priceValue: Int64? {
        let digits = price.filter(\.isNumber)
        return digits.isEmpty ? 0 : Int64(digits)
    }

    private var isValid: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 100 && priceValue != nil && autoReply.count <= 500
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(bundle.loc("Title"), text: $title)
                    TextField(bundle.loc("Price (₫)"), text: $price).keyboardType(.numberPad)
                    Picker(bundle.loc("Condition"), selection: $condition) {
                        ForEach(ListingCondition.allCases, id: \.self) { Text(bundle.loc($0.label)).tag($0) }
                    }
                    ListingLocationRow(place: $place)
                }
                Section {
                    Toggle(bundle.loc("Auto-reply"), isOn: $autoReplyOn)
                    if autoReplyOn {
                        TextField(bundle.loc("Your reply"), text: $autoReply, axis: .vertical).lineLimit(2...4)
                    }
                } footer: {
                    Text("Sent once to each buyer who messages you about this listing.", bundle: bundle)
                }
                Section {
                    Toggle(bundle.loc("Hide from friends"), isOn: $hideFromFriends)
                } footer: {
                    Text("Your connections won't see this listing.", bundle: bundle)
                }
            }
            .tint(themeManager.theme.primary)
            .navigationTitle(Text("Edit listing", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ConfirmCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Save")) {
                        isSaving = true
                        var fields: [String: Any] = [
                            "title": title, "price": priceValue ?? 0, "condition": condition.rawValue,
                            "location": place.map { String($0.name.prefix(150)) } ?? "",
                            "auto_reply": autoReplyOn ? autoReply : "",
                            "hide_from_friends": hideFromFriends,
                        ]
                        if let place {
                            fields["latitude"] = place.latitude
                            fields["longitude"] = place.longitude
                        } else {
                            fields["clear_coordinates"] = true
                        }
                        Task<Void, Never>(name: nil) {
                            if await onSave(fields) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
        }
    }
}
