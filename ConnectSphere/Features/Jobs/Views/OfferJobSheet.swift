import SwiftUI

// MARK: - Offer job sheet
/// Full height: the HR's open jobs as cards, like the Jobs tab. Tapping one
/// offers it on the "Open to work" post as a comment.
struct OfferJobSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = OfferJobViewModel()
    let onPick: (JobListing) -> Void

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    Text("Offer one of your open jobs. It's posted as a comment with the job's card.", bundle: bundle)
                        .scaledFont(13)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if viewModel.isLoading {
                        ProgressView().padding(.top, 40)
                    } else if viewModel.jobs.isEmpty {
                        EmptyStateView(systemImage: "briefcase",
                                       title: viewModel.errorMessage ?? bundle.loc("You have no open jobs yet."))
                            .padding(.top, 40)
                    } else {
                        ForEach(viewModel.jobs) { job in
                            Button {
                                onPick(job)
                                dismiss()
                            } label: {
                                // No save button here: the card only picks.
                                JobCard(job: job, showsMatch: false, onToggleSave: {})
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Offer a job"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
            }
            .task { await viewModel.load(token: token) }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Job card in comments
/// The job an HR offered, inside their comment. Opens the job.
struct CommentJobCard: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    let job: CommentJobDTO

    var body: some View {
        NavigationLink { JobDetailView(jobId: job.id) { _ in } } label: {
            HStack(spacing: 10) {
                Image(systemName: "briefcase.fill")
                    .scaledFont(18)
                    .foregroundColor(themeManager.theme.primary)
                    .frame(width: 36, height: 36)
                    .background(themeManager.theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textPrimary(colorScheme)).lineLimit(1)
                    Text([job.company, job.workFormat.map { bundle.loc(JobListing.formatLabel($0)) }, job.location.map(bundle.address)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .scaledFont(12).lineLimit(1)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                    Text("View job", bundle: bundle).scaledFont(12, .semibold)
                        .foregroundColor(themeManager.theme.primary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundColor(AppColors.textTertiary(colorScheme))
            }
            .padding(10)
            .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppColors.textTertiary(colorScheme).opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Offer button
/// The briefcase beside the comment box: a verified HR, on an "Open to work"
/// post, offers one of their jobs.
struct OfferJobButton: View {
    @Environment(\.appBundle) private var bundle
    @Environment(ThemeManager.self) private var themeManager
    let postId: String
    let viewModel: CommentViewModel
    /// After the job's comment is posted (count +1, scroll to it).
    var onOffered: () -> Void = {}
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Image(systemName: "briefcase.fill")
                .scaledFont(20)
                .foregroundColor(themeManager.theme.primary)
        }
        .accessibilityLabel(Text(bundle.loc("Offer a job")))
        .sheet(isPresented: $picking) {
            OfferJobSheet { job in
                Task { if await viewModel.offerJob(job, postId: postId) { onOffered() } }
            }
        }
    }
}
