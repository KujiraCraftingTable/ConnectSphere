import SwiftUI

// MARK: - Reports list
/// "..." › Manage community › Reports: reported posts and members, one case
/// each, for the community's admins and moderators.
struct CommunityReportsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: CommunityReportsViewModel
    @State private var showResolved = false
    @State private var opened: CommunityReportCase?

    /// `isAdmin` nil (opened from a notification): the screen looks the role up.
    init(communityId: String, isAdmin: Bool?) {
        _viewModel = State(initialValue: CommunityReportsViewModel(communityId: communityId, isAdmin: isAdmin))
    }

    private var token: String { appState.authToken ?? "" }
    private var cases: [CommunityReportCase] { showResolved ? viewModel.resolved : viewModel.pending }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("", selection: $showResolved) {
                    Text(viewModel.pendingCount > 0
                         ? "\(bundle.loc("Pending")) · \(viewModel.pendingCount)" : bundle.loc("Pending")).tag(false)
                    Text("Resolved", bundle: bundle).tag(true)
                }
                .pickerStyle(.segmented)

                if cases.isEmpty && !viewModel.isLoading {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.shield").scaledFont(36)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                        Text(showResolved ? bundle.loc("No resolved reports") : bundle.loc("No pending reports"))
                            .scaledFont(15).foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                    .padding(.top, 60)
                }
                ForEach(cases) { item in
                    Button { opened = item } label: { ReportCaseRow(item: item) }
                        .buttonStyle(.plain)
                }
                if viewModel.isLoading && cases.isEmpty { ProgressView().padding() }
            }
            .padding(12)
        }
        .appBackground()
        .navigationTitle(Text("Reports", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: showResolved) { await viewModel.load(resolved: showResolved, token: token) }
        .task { await viewModel.loadRoleIfNeeded(token: token) }
        .refreshable { await viewModel.load(resolved: showResolved, token: token) }
        .navigationDestination(item: $opened) { item in
            CommunityReportCaseView(communityId: viewModel.communityId, targetId: item.targetId, isAdmin: viewModel.isAdmin ?? false) {
                viewModel.caseDecided(item.targetId)
            }
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: { Text(viewModel.errorMessage ?? "") }
    }
}

// MARK: - Case row
/// One case in the list: what was reported, how many times, and why.
struct ReportCaseRow: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    let item: CommunityReportCase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(name: item.personName ?? "?", colorHex: item.personAvatarColor ?? "#888888",
                       imageURL: item.personAvatarUrl, diameter: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.personName ?? bundle.loc("Deleted account"))
                        .scaledFont(15, .semibold).foregroundColor(AppColors.textPrimary(colorScheme))
                    Text(item.isPost ? bundle.loc("Reported post") : bundle.loc("Reported member"))
                        .scaledFont(12).foregroundColor(AppColors.textSecondary(colorScheme))
                }
                Spacer()
                countChip
            }
            if item.isPost, let text = item.postContent, !text.isEmpty {
                Text(text).scaledFont(14).lineLimit(3).foregroundColor(AppColors.textPrimary(colorScheme))
            }
            if item.isPost, let url = APIConfig.mediaURL(item.postImage) {
                RemoteImage(url: url, maxPixelSize: 600) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                    else { Color.gray.opacity(0.15) }
                }
                .frame(height: 120).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 6) {
                ForEach(item.reasons.prefix(3), id: \.reason) { r in
                    Text(r.count > 1 ? "\(reasonLabel(r.reason)) · \(r.count)" : reasonLabel(r.reason))
                        .scaledFont(12, .medium)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(AppColors.danger(colorScheme).opacity(0.12)))
                        .foregroundColor(AppColors.danger(colorScheme))
                }
                Spacer()
                Text(item.latestAt.timeAgoString).scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            if item.status != "pending" {
                Text(item.status == "dismissed" ? bundle.loc("Kept, no action") : bundle.loc("Action taken"))
                    .scaledFont(12, .medium).foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .padding(14)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var countChip: some View {
        Text(item.reportCount == 1 ? bundle.loc("1 report")
                                   : String(format: bundle.loc("%lld reports"), item.reportCount))
            .scaledFont(12, .bold)
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.red))
    }

    private func reasonLabel(_ raw: String) -> String {
        bundle.loc(ModerationReason(communityValue: raw)?.displayName ?? raw.capitalized)
    }
}
