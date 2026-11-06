import SwiftUI

/// Moderation queue for admin/moderators. Shows pending and resolved reports
struct ModerationQueueView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var viewModel: ModerationViewModel
    @State private var selectedTab = 0

    let coverColor: String

    init(communityId: String, token: String, coverColor: String) {
        _viewModel  = State(initialValue: ModerationViewModel(communityId: communityId, token: token))
        self.coverColor = coverColor
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker: Pending | Resolved
            Picker("", selection: $selectedTab) {
                Text(String(format: bundle.loc("Pending (%d)"), viewModel.pendingCount)).tag(0)
                Text("Resolved", bundle: bundle).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(12)

            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let items = selectedTab == 0 ? viewModel.pendingReports : viewModel.resolvedReports
                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(items) { item in
                            ReportItemCard(
                                item:       item,
                                isPending:  selectedTab == 0,
                                coverColor: coverColor,
                                onRemove: { Task<Void, Never>(name: nil) { await viewModel.removeContent(item.id) } },
                                onBan:    { Task<Void, Never>(name: nil) { await viewModel.banMember(item.id) } },
                                onDismiss:{ Task<Void, Never>(name: nil) { await viewModel.dismiss(item.id) } }
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle(bundle.loc("Moderation Queue"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.fetchQueue(status: "pending") }
        .onChange(of: selectedTab) { _, newTab in
            Task<Void, Never>(name: nil) {
                await viewModel.fetchQueue(status: newTab == 0 ? "pending" : "resolved")
            }
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(selectedTab == 0 ? bundle.loc("No pending reports") : bundle.loc("No resolved reports"))
                .scaledFont(16, .medium)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
