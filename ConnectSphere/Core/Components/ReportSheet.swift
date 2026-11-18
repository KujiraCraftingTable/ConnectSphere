import SwiftUI

/// Reporting anything: pick a reason, add detail if you like, send. Shown as
/// `.sheet(item: $reportSubject) { ReportSheet(subject: $0) }` from every
/// place something can be reported. The person reported is never told who.
struct ReportSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) private var bundle

    /// Offered once the report is in, as Instagram and X do.
    var blockUser: (id: String, name: String)?
    /// Called when the sheet closes after a report was sent, so the caller can
    /// take the item out of the reporter's view.
    var onReported: (() -> Void)?

    @State private var viewModel: ReportViewModel

    init(subject: ReportSubject, blockUser: (id: String, name: String)? = nil, onReported: (() -> Void)? = nil) {
        self.blockUser = blockUser
        self.onReported = onReported
        _viewModel = State(initialValue: ReportViewModel(subject: subject))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.submitted {
                        submittedState
                    } else {
                        reasonList
                        if case .content(.message, _, _) = viewModel.subject {
                            Text("Your report includes this message and up to 5 earlier messages from this person.", bundle: bundle)
                                .scaledFont(13)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .padding(.horizontal, 20)
                                .padding(.top, 12)
                        }
                        detailField
                        if let err = viewModel.errorMessage {
                            Text(err)
                                .scaledFont(13)
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                        }
                    }
                }
            }
            .navigationTitle(bundle.loc(viewModel.subject.sheetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!viewModel.submitted)
            .toolbar {
                if viewModel.submitted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(bundle.loc("Done")) { close() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        ConfirmCancelButton(hasChanges: viewModel.selectedReason != nil || !viewModel.detail.isEmpty) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(bundle.loc("Submit report")) {
                            Task<Void, Never>(name: nil) { await viewModel.submit() }
                        }
                        .scaledFont(16, .semibold)
                        .disabled(!viewModel.canSubmit)
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func close() {
        dismiss()
        onReported?()
    }

    // MARK: - Reason list

    private var reasonList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why are you reporting this?", bundle: bundle)
                .scaledFont(14, .semibold)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)

            ForEach(viewModel.subject.reasons, id: \.self) { reason in
                Button {
                    viewModel.selectedReason = reason
                } label: {
                    HStack {
                        Text(bundle.loc(reason.displayName))
                            .scaledFont(16)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        Image(systemName: viewModel.selectedReason == reason ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(viewModel.selectedReason == reason
                                             ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.selectedReason == reason ? .isSelected : [])
                Divider().padding(.leading, 20)
            }
        }
    }

    // MARK: - Detail field

    private var detailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Additional details (optional)", bundle: bundle)
                .scaledFont(14, .semibold)
                .foregroundColor(AppColors.textSecondary(colorScheme))

            TextEditor(text: $viewModel.detail)
                .axID(AXID.Report.details)
                .scaledFont(16)
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
            Text("Thanks for letting us know", bundle: bundle)
                .scaledFont(20, .bold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text("We'll review it and tell you what we decide in Settings › Account status. They won't know it was you.", bundle: bundle)
                .scaledFont(15)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let blockUser {
                if viewModel.blocked {
                    Label(String(format: bundle.loc("You blocked %@"), blockUser.name), systemImage: "checkmark")
                        .scaledFont(15, .semibold)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .padding(.top, 8)
                } else {
                    Button(role: .destructive) {
                        Task<Void, Never>(name: nil) { await viewModel.block(userId: blockUser.id) }
                    } label: {
                        Text(String(format: bundle.loc("Block %@"), blockUser.name))
                            .scaledFont(16, .semibold)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .overlay(Capsule().stroke(Color.red.opacity(0.6)))
                    }
                    .padding(.top, 8)
                }
            }
            if let err = viewModel.errorMessage {
                Text(err).scaledFont(13).foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }
}
