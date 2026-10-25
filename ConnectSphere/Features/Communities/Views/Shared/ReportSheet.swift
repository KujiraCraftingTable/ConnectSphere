import SwiftUI

/// Bottom sheet for reporting a community member — used from the member row's
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
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(.horizontal, 20)
                    }
                }
                Spacer()
            }
            .navigationTitle(bundle.loc(targetType == "post" ? "Report post"
                                        : targetType == "community" ? "Report community" : "Report member"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                if !viewModel.submitted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(bundle.loc("Submit report")) {
                            Task<Void, Never>(name: nil) {
                                await viewModel.submit(targetType: targetType, targetId: targetId,
                                                       communityId: communityId, token: token)
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
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
                .font(.system(size: 14, weight: .semibold))
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
                            .font(.system(size: 16))
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
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textSecondary(colorScheme))

            TextEditor(text: $viewModel.detail)
                .font(.system(size: 15))
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
                .font(.system(size: 56))
                .foregroundColor(.green)
            Text("Report submitted", bundle: bundle)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text("Thank you. An admin will review this report soon.", bundle: bundle)
                .font(.system(size: 15))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(bundle.loc("Done")) { dismiss() }
                .font(.system(size: 16, weight: .semibold))
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
