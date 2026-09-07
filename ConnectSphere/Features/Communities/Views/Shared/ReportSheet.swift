import SwiftUI

/// Bottom sheet for reporting a post or a member.
/// Used from CommunityPostCard context menu and member row context menu.
struct ReportSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBundle) var bundle

    let targetType: String           // "post" | "member"
    let targetId:   String
    let communityId: String
    let token: String

    @State private var selectedReason: ReportReason? = nil
    @State private var detail: String = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if submitted {
                    submittedState
                } else {
                    reasonList
                    detailField
                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(.horizontal, 20)
                    }
                }
                Spacer()
            }
            .navigationTitle(bundle.loc(targetType == "post" ? "Report post" : "Report member"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                if !submitted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(bundle.loc("Submit report")) {
                            Task<Void, Never>(name: nil) { await submit() }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .disabled(selectedReason == nil || isSubmitting)
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
                    selectedReason = reason
                } label: {
                    HStack {
                        Text(bundle.loc(reason.displayName))
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        if selectedReason == reason {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.purple)
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

            TextEditor(text: $detail)
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
                .background(Color.purple)
                .clipShape(Capsule())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Submit

    private func submit() async {
        guard let reason = selectedReason else { return }
        isSubmitting = true
        errorMessage = nil

        let path: String
        var body: [String: Any] = ["reason": reason.rawValue]
        if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["detail"] = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if targetType == "post" {
            path = "/posts/\(targetId)/report"
            body["communityId"] = communityId
        } else {
            path = "/communities/\(communityId)/members/\(targetId)/report"
        }

        do {
            let bodyData = try? JSONSerialization.data(withJSONObject: body)
            _ = try await NetworkClient.shared.fetch(
                OKResponse.self,
                path: path,
                method: "POST", token: token, bodyData: bodyData
            )
            submitted = true
        } catch {
            if case APIError.serverError(_, let msg) = error { errorMessage = msg }
            else { errorMessage = bundle.loc("Could not submit report. Please try again.") }
        }
        isSubmitting = false
    }
}
