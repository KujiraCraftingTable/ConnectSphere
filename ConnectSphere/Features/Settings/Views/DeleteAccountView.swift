import SwiftUI

/// Deletes (soft-deletes) the account — opened from Privacy & Security.
/// Confirmed with a password; for a Google account with no password, type "DELETE" instead.
/// On success → logs out to the sign-in screen.
struct DeleteAccountView: View {
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: DeleteAccountViewModel
    @State private var showFinalConfirm = false

    init(hasPassword: Bool) {
        _viewModel = State(initialValue: DeleteAccountViewModel(hasPassword: hasPassword))
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
                    if viewModel.hasPassword {
                        SecureField(bundle.loc("Enter your password to confirm"), text: $viewModel.password)
                    } else {
                        TextField(bundle.loc("Type DELETE to confirm"), text: $viewModel.confirmationText)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                }

                if let errorMessage = viewModel.errorMessage {
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
                        if viewModel.isDeleting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Delete my account", bundle: bundle)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!viewModel.canDelete)
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
                    Task {
                        // The token is now invalid — back to sign-in.
                        if await viewModel.deleteAccount() { appState.logout() }
                    }
                }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            } message: {
                Text("This can't be undone.", bundle: bundle)
            }
        }
        .interactiveDismissDisabled(viewModel.isDeleting)
    }
}
