import SwiftUI

/// Moderation queue for admin/moderators — shows pending and resolved reports
struct ModerationQueueView: View {
    @Environment(\.colorScheme) var colorScheme
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
                Text("Pending (\(viewModel.pendingCount))").tag(0)
                Text("Resolved").tag(1)
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
        .navigationTitle("Moderation Queue")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.fetchQueue(status: "pending") }
        .onChange(of: selectedTab) { _, newTab in
            Task<Void, Never>(name: nil) {
                await viewModel.fetchQueue(status: newTab == 0 ? "pending" : "resolved")
            }
        }
        .alert("Lỗi", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(selectedTab == 0 ? "No pending reports" : "No resolved reports")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
