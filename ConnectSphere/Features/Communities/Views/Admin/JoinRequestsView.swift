import SwiftUI

/// Shows pending join requests for a private community; visible to admins and moderators only.
struct JoinRequestsView: View {
    @Environment(\.colorScheme) var colorScheme
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
                                    Label("Decline", systemImage: "xmark")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task<Void, Never>(name: nil) { await viewModel.approve(request.id) }
                                } label: {
                                    Label("Approve", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Join Requests")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.fetchRequests() }
        .alert("Lỗi", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.user.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text("@\(request.user.username)")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                Text(request.requestedAt.timeAgoString)
                    .font(.system(size: 12))
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
                .font(.system(size: 13, weight: .bold))
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
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No pending requests")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text("Join requests will appear here")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
