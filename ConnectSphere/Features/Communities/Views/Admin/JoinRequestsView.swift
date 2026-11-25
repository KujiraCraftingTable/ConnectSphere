import SwiftUI

/// The Join tab of a private community's Requests (admins and moderators).
struct JoinRequestsView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @State private var viewModel: JoinRequestsViewModel
    /// A decision waiting for its confirmation.
    @State private var pending: (request: JoinRequest, approve: Bool)?

    /// How many are waiting, for the tab's label.
    var onCount: (Int) -> Void = { _ in }

    init(communityId: String, token: String, onCount: @escaping (Int) -> Void = { _ in }) {
        _viewModel = State(initialValue: JoinRequestsViewModel(communityId: communityId, token: token))
        self.onCount = onCount
    }

    // MARK: - Body
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
                                    pending = (request, false)
                                } label: {
                                    Label(bundle.loc("Decline"), systemImage: "xmark")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    pending = (request, true)
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
        .task { await viewModel.fetchRequests() }
        .onChange(of: viewModel.requests.count) { _, n in onCount(n) }
        .onAppear { viewModel.startListening() }
        .onDisappear { viewModel.stopListening() }
        .alert(pending.map { String(format: bundle.loc($0.approve ? "Let %@ join?" : "Decline %@'s request?"),
                                    $0.request.user.displayName) } ?? "",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(bundle.loc("Cancel"), role: .cancel) {}
            if let p = pending {
                Button(bundle.loc(p.approve ? "Approve" : "Decline"), role: p.approve ? nil : .destructive) {
                    let id = p.request.id
                    Task<Void, Never>(name: nil) {
                        if p.approve { await viewModel.approve(id) } else { await viewModel.reject(id) }
                    }
                }
            }
        } message: {
            Text(pending?.approve == true ? bundle.loc("They'll become a member and can see and post in the community.")
                                          : bundle.loc("They won't join. They can ask again later."))
        }
        .alert(bundle.loc("Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(bundle.loc("OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Request rows
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
                    pending = (request, false)
                }
                actionButton(icon: "checkmark", color: .green) {
                    pending = (request, true)
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

    // MARK: - Empty state
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
