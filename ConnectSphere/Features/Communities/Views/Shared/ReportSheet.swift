import SwiftUI

/// Bottom sheet for reporting a community member. Used from the member row's
/// context menu on `CommunityDetailView`. Post reports go through `PostCard`'s
/// own inline confirmation-dialog flow instead (`targetType` here still
/// accepts "post" server-side if a future caller needs it).
struct ReportSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBundle) var bundle

    let targetType: String           // "post" | "member" | "community"
    let targetId:   String
    let communityId: String
    let token: String

    @State private var viewModel = ReportViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.submitted {
                    submittedState
                } else {
                    reasonList
                    detailField
                    if let err = viewModel.errorMessage {
                        Text(err)
                            .scaledFont(13)
                            .foregroundColor(.red)
                            .padding(.horizontal, 20)
                    }
                }
                Spacer()
            }
            .navigationTitle(bundle.loc(targetType == "post" ? "Report post"
                                        : targetType == "community" ? "Report community" : "Report member"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton(hasChanges: viewModel.hasChanges) { dismiss() }
                }
                if !viewModel.submitted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(bundle.loc("Submit report")) {
                            Task<Void, Never>(name: nil) {
                                await viewModel.submit(targetType: targetType, targetId: targetId,
                                                       communityId: communityId, token: token)
                            }
                        }
                        .scaledFont(15, .semibold)
                        .disabled(!viewModel.canSubmit)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Reason list

    private var reasonList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why are you reporting this content?", bundle: bundle)
                .scaledFont(14, .semibold)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)

            ForEach(ReportReason.allCases, id: \.self) { reason in
                Button {
                    viewModel.selectedReason = reason
                } label: {
                    HStack {
                        Text(bundle.loc(reason.displayName))
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        if viewModel.selectedReason == reason {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(themeManager.theme.primary)
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                Divider()
                    .padding(.leading, 20)
            }
        }
    }

    // MARK: - Detail field

    private var detailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Additional details (optional)", bundle: bundle)
                .scaledFont(13, .medium)
                .foregroundColor(AppColors.textSecondary(colorScheme))

            TextEditor(text: $viewModel.detail)
                .scaledFont(15)
                .frame(height: 80)
                .padding(10)
                .background(AppColors.elevated(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    // MARK: - Submitted state

    private var submittedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(56)
                .foregroundColor(.green)
            Text("Report submitted", bundle: bundle)
                .scaledFont(20, .bold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text("Thank you. An admin will review this report soon.", bundle: bundle)
                .scaledFont(15)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(bundle.loc("Done")) { dismiss() }
                .scaledFont(16, .semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
                .background(themeManager.theme.primary)
                .clipShape(Capsule())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
