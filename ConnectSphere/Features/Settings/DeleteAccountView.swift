import SwiftUI

/// Deletes (soft-deletes) the account — opened from Privacy & Security.
/// Confirmed with a password; for a Google account with no password, type "DELETE" instead.
/// On success → logs out to the sign-in screen.
struct DeleteAccountView: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmationText = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var showFinalConfirm = false

    private let profileRepo = ProfileRepository()

    private var hasPassword: Bool { appState.currentUser?.hasPassword ?? true }

    private var canDelete: Bool {
        !isDeleting && (hasPassword ? !password.isEmpty : confirmationText == "DELETE")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.red)
                        Text("Your profile will be anonymized and you won't be able to sign in again. Posts and messages you sent will remain, shown as \"Deleted User\".", bundle: bundle)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if hasPassword {
                        SecureField(bundle.loc("Enter your password to confirm"), text: $password)
                    } else {
                        TextField(bundle.loc("Type DELETE to confirm"), text: $confirmationText)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showFinalConfirm = true
                    } label: {
                        if isDeleting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Delete my account", bundle: bundle)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canDelete)
                }
            }
            .navigationTitle(bundle.loc("Delete account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }
            .confirmationDialog(
                bundle.loc("Delete account?"),
                isPresented: $showFinalConfirm,
                titleVisibility: .visible
            ) {
                Button(bundle.loc("Delete my account"), role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            } message: {
                Text("This can't be undone.", bundle: bundle)
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func deleteAccount() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            try await profileRepo.deleteAccount(
                password: hasPassword ? password : nil,
                confirmation: hasPassword ? nil : confirmationText
            )
            // Account is now disabled — the token is no longer valid, so go back to sign-in
            appState.logout()
        } catch {
            errorMessage = (error as NSError).code == 401
                ? bundle.loc("Password is incorrect")
                : bundle.loc("Couldn't delete account, please try again")
        }
    }
}
