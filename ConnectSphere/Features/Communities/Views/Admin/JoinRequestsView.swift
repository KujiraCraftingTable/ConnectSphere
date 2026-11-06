import SwiftUI

/// Shows pending join requests for a private community; visible to admins and moderators only.
struct JoinRequestsView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var viewModel: JoinRequestsViewModel

    init(communityId: String, token: String) {
        _viewModel = State(initialValue: JoinRequestsViewModel(communityId: communityId, token: token))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.requests.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.requests) { request in
                        requestRow(request)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task<Void, Never>(name: nil) { await viewModel.reject(request.id) }
                                } label: {
                                    Label(bundle.loc("Decline"), systemImage: "xmark")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task<Void, Never>(name: nil) { await viewModel.approve(request.id) }
                                } label: {
                                    Label(bundle.loc("Approve"), systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(bundle.loc("Join Requests"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.fetchRequests() }
        .onAppear { viewModel.startListening() }
        .onDisappear { viewModel.stopListening() }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private func requestRow(_ request: JoinRequest) -> some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle().fill(Color(hex: request.user.avatarColor))
                Text(String(request.user.displayName.prefix(1)))
                    .scaledFont(15, .bold)
                    .foregroundColor(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.user.displayName)
                    .scaledFont(15, .medium)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text("@\(request.user.username)")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                Text(request.requestedAt.timeAgoString)
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            Spacer()

            // Quick action buttons
            HStack(spacing: 8) {
                actionButton(icon: "xmark", color: .red) {
                    Task<Void, Never>(name: nil) { await viewModel.reject(request.id) }
                }
                actionButton(icon: "checkmark", color: .green) {
                    Task<Void, Never>(name: nil) { await viewModel.approve(request.id) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func actionButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .scaledFont(13, .bold)
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.plus")
                .scaledFont(40)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(bundle.loc("No pending requests"))
                .scaledFont(16, .medium)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text(bundle.loc("Join requests will appear here"))
                .scaledFont(14)
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
