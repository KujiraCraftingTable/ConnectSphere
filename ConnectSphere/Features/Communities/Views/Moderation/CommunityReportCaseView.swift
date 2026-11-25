import SwiftUI

/// One reported post or member: why people reported it (not who), what staff
/// did about this person here before, and the decision. Every decision asks first.
struct CommunityReportCaseView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: CommunityReportCaseViewModel
    @State private var note = ""
    @State private var confirming: CommunityReportDecision?
    let isAdmin: Bool
    /// The decision was saved: the list drops this case.
    let onDecided: () -> Void

    init(communityId: String, targetId: String, isAdmin: Bool, onDecided: @escaping () -> Void) {
        _viewModel = State(initialValue: CommunityReportCaseViewModel(communityId: communityId, targetId: targetId))
        self.isAdmin = isAdmin
        self.onDecided = onDecided
    }

    private var token: String { appState.authToken ?? "" }

    // MARK: - Body
    var body: some View {
        ScrollView {
            if let detail = viewModel.detail {
                VStack(alignment: .leading, spacing: 18) {
                    // The same card as the Reports list, reasons and count included.
                    ReportCaseRow(item: detail.summary)
                    // What reporters wrote, when they wrote anything; the reasons are on the card.
                    let notes = detail.reports.compactMap { r in r.detail.flatMap { $0.isEmpty ? nil : (r, $0) } }
                    if !notes.isEmpty {
                        section("What reporters said") {
                            ForEach(notes, id: \.0.id) { report, text in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\u{201C}\(text)\u{201D}").scaledFont(14)
                                        .foregroundColor(AppColors.textPrimary(colorScheme))
                                    Text("\(reasonLabel(report.reason)) · \(report.createdAt.timeAgoString)")
                                        .scaledFont(12).foregroundColor(AppColors.textTertiary(colorScheme))
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .surfaceBackground()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    if let approver = detail.approvedBy {
                        section("Approved by") {
                            HStack(spacing: 12) {
                                Avatar(name: approver.displayName, colorHex: approver.avatarColor ?? "#888888",
                                       imageURL: approver.avatarUrl, diameter: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(approver.displayName).scaledFont(15, .semibold)
                                        .foregroundColor(AppColors.textPrimary(colorScheme))
                                    Text("@\(approver.username)").scaledFont(13)
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                }
                                Spacer()
                                Text(approver.approvedAt.timeAgoString).scaledFont(12)
                                    .foregroundColor(AppColors.textTertiary(colorScheme))
                            }
                            .padding(14)
                            .surfaceBackground()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    if detail.summary.status == "pending" {
                        if detail.canDecide {
                            decisionSection(detail.summary)
                        } else {
                            Text(bundle.loc("You reported this, so another moderator or the admin will decide it."))
                                .scaledFont(13)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            } else if viewModel.isLoading {
                ProgressView().padding(.top, 60)
            }
        }
        .appBackground()
        .navigationTitle(Text("Report", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(token: token) }
        .alert(confirming.map { bundle.loc(confirmTitle($0)) } ?? "",
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { decision in
            Button(bundle.loc("Cancel"), role: .cancel) {}
            Button(bundle.loc(buttonTitle(decision)), role: decision.isDestructive ? .destructive : nil) {
                Task {
                    if await viewModel.decide(decision, note: note, token: token) {
                        onDecided()
                        dismiss()
                    }
                }
            }
        } message: { decision in
            Text(bundle.loc(confirmMessage(decision)))
        }
        .alert(bundle.loc("Error"), isPresented: Binding(
            get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        } message: { Text(viewModel.errorMessage ?? "") }
    }

    // MARK: - Decision
    private func decisionSection(_ item: CommunityReportCase) -> some View {
        section("Decision") {
            TextField(bundle.loc("Note (optional, sent with a warning)"), text: $note, axis: .vertical)
                .lineLimit(2...4)
                .padding(12)
                .surfaceBackground()
                .clipShape(RoundedRectangle(cornerRadius: 12))
            ForEach(CommunityReportDecision.choices(isPost: item.isPost, isAdmin: isAdmin)) { d in
                Button { confirming = d } label: {
                    Text(bundle.loc(buttonTitle(d))).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(d.isDestructive ? AppColors.danger(colorScheme) : AppColors.textSecondary(colorScheme))
                .disabled(viewModel.isDeciding)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bundle.loc(title)).scaledFont(13, .semibold)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            content()
        }
    }

    // MARK: - Labels
    private func reasonLabel(_ raw: String) -> String {
        bundle.loc(ModerationReason(communityValue: raw)?.displayName ?? raw.capitalized)
    }

    private func buttonTitle(_ d: CommunityReportDecision) -> String {
        switch d {
        case .keep:       "Keep, no action"
        case .remove:     "Remove post"
        case .removeWarn: "Remove post and warn"
        case .removeBan:  "Remove post and ban"
        case .ban:        "Ban from community"
        }
    }

    private func confirmTitle(_ d: CommunityReportDecision) -> String {
        switch d {
        case .keep:       "Keep it?"
        case .remove:     "Remove this post?"
        case .removeWarn: "Remove and warn?"
        case .removeBan, .ban: "Ban them from this community?"
        }
    }

    private func confirmMessage(_ d: CommunityReportDecision) -> String {
        switch d {
        case .keep:       "The reports are closed and the reporters are told no action was taken."
        case .remove:     "The post is taken down and its author is told. The reporters hear it was removed."
        case .removeWarn: "The post is taken down and its author gets a warning, with your note."
        case .removeBan:  "The post is taken down, they're removed from the community and can't join again."
        case .ban:        "They're removed from the community and can't join again."
        }
    }
}
