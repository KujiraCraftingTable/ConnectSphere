import SwiftUI

/// Your confirmed sales and purchases, newest first. Reached from
/// Settings › Marketplace. Each deal stays here 3 years, even after the
/// listing or the other person's account is gone.
struct DealHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: DealHistoryViewModel

    init(mode: AppMode) {
        _viewModel = State(initialValue: DealHistoryViewModel(mode: mode))
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        List {
            if viewModel.deals.isEmpty, viewModel.hasLoaded, !viewModel.isLoading {
                Text(viewModel.errorMessage ?? bundle.loc("No sales or purchases yet"))
                    .scaledFont(15)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.deals) { deal in
                        row(deal)
                    }
                } footer: {
                    Text("Each deal is kept for 3 years, even if the listing or an account is deleted, as Vietnamese e-commerce law requires.", bundle: bundle)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Deal history"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !viewModel.deals.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: viewModel.exportText) {
                        Label(bundle.loc("Save a copy"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.deals.isEmpty { ProgressView() }
        }
        .task { await viewModel.load(token: token) }
        .refreshable { await viewModel.load(token: token) }
    }

    private func row(_ deal: Deal) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: deal.role == .sold ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill")
                .scaledFont(22)
                .foregroundColor(deal.role == .sold ? AppColors.success(colorScheme) : AppColors.textSecondary(colorScheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(deal.itemTitle)
                    .scaledFont(16, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(deal.role == .sold
                     ? String(format: bundle.loc("Sold to @%@"), deal.otherUsername)
                     : String(format: bundle.loc("Bought from @%@"), deal.otherUsername))
                    .scaledFont(14)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                Text(deal.confirmedAt.formatted(date: .abbreviated, time: .omitted))
                    .scaledFont(13)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            Spacer(minLength: 8)
            Text(DealHistoryViewModel.amount(deal))
                .scaledFont(15, .semibold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
