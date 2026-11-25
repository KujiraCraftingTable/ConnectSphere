import SwiftUI

/// Full height: the seller's chats with a search box, to put an item on
/// deposit for a buyer or to confirm a buyer's deposit as sold.
struct ListingBuyerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ListingBuyerViewModel
    @State private var confirmingSave = false
    private let listing: ListingData
    private let onSaved: (Post) -> Void

    init(mode: ListingBuyerViewModel.Mode, listing: ListingData, onSaved: @escaping (Post) -> Void) {
        _viewModel = State(initialValue: ListingBuyerViewModel(mode: mode, listing: listing))
        self.listing = listing
        self.onSaved = onSaved
    }

    private var isDeposit: Bool {
        if case .deposit = viewModel.mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                itemCard
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                if let limit = viewModel.amountLimitWarning {
                    Text(String(format: bundle.loc("You can put up to %lld on deposit for this buyer."), limit))
                        .scaledFont(13)
                        .foregroundColor(AppColors.danger(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                List {
                    if viewModel.isLoading && viewModel.buyers.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if viewModel.buyers.isEmpty {
                        Text(isDeposit ? "No chats yet. Message the buyer first." : "No deposits yet", bundle: bundle)
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    ForEach(viewModel.shown) { buyer in
                        Button { viewModel.pick(buyer) } label: { row(buyer) }
                            .buttonStyle(.plain)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error).foregroundColor(AppColors.danger(colorScheme))
                    }
                }
                .listStyle(.plain)
                .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Text("Search chats", bundle: bundle))
            }
            .navigationTitle(Text(isDeposit ? "Who's it on deposit for?" : "Who received it?", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
            .task { await viewModel.load(token: appState.authToken ?? "") }
        }
        .presentationDetents([.large])
    }

    // MARK: - Item & deposit
    /// The item at the top, with the deposit control or what's left on its right.
    private var itemCard: some View {
        HStack(spacing: 12) {
            if let url = APIConfig.mediaURL(viewModel.item?.imageUrls.first ?? listing.items.first?.imageUrls.first) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { AppColors.elevated(colorScheme) }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.item?.title ?? listing.title)
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                if let item = viewModel.item {
                    Text(item.priceText(loc: bundle.loc))
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            Spacer(minLength: 8)
            if let item = viewModel.item {
                if isDeposit {
                    depositControl
                } else {
                    // Only confirming a deposit as sold changes it.
                    Text("\(item.left)")
                        .scaledFont(17, .semibold)
                        .monospacedDigit()
                        .frame(minWidth: 44, minHeight: 34)
                        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(10)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
    }

    /// `− [n] +`, from nothing up to what this buyer holds plus the free units.
    private var depositControl: some View {
        QuantityStepper(value: $viewModel.amount, range: 0...viewModel.maxAmount,
                        isInvalid: viewModel.amountLimitWarning != nil)
            .disabled(viewModel.selected == nil)
            .opacity(viewModel.selected == nil ? 0.4 : 1)
    }

    // MARK: - Buyers
    private func row(_ buyer: ListingBuyerViewModel.Buyer) -> some View {
        HStack(spacing: 12) {
            Avatar(name: buyer.name, colorHex: buyer.avatarColor, imageURL: buyer.avatarUrl, size: .md)
            VStack(alignment: .leading, spacing: 2) {
                Text(buyer.name).foregroundColor(AppColors.textPrimary(colorScheme))
                Text("@\(buyer.username)").scaledFont(13).foregroundColor(AppColors.textSecondary(colorScheme))
            }
            Spacer()
            if buyer.deposit > 0 {
                Text(String(format: bundle.loc("%lld on deposit"), buyer.deposit))
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            if viewModel.allowsSeveral {
                // Checkboxes: several buyers can be confirmed at once.
                Image(systemName: viewModel.isPicked(buyer) ? "checkmark.circle.fill" : "circle")
                    .scaledFont(20)
                    .foregroundColor(viewModel.isPicked(buyer) ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
            } else if viewModel.isPicked(buyer) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(themeManager.theme.primary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Save
    private func save() {
        Task {
            if let post = await viewModel.save(token: appState.authToken ?? "") {
                onSaved(post)
                dismiss()
            }
        }
    }

    private var saveBar: some View {
        Button {
            confirmingSave = true
        } label: {
            Group {
                if viewModel.isSaving { ProgressView().tint(.white) }
                else { Text(isDeposit ? "Save deposit" : "Confirm sold & send review card", bundle: bundle) }
            }
            .scaledFont(15, .semibold)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(themeManager.theme.primary.opacity(viewModel.canSave ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSave)
        .alert(viewModel.saveConfirmation ?? "", isPresented: $confirmingSave) {
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc(isDeposit ? "Save" : "Confirm")) { save() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
