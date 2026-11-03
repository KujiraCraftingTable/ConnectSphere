import SwiftUI

/// Changes an existing password, or sets one for the first time (Google account).
/// Opened from Privacy & Security.
struct ChangePasswordView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ChangePasswordViewModel
    @State private var showSuccess = false

    init(hasPassword: Bool) {
        _viewModel = State(initialValue: ChangePasswordViewModel(hasPassword: hasPassword))
    }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.hasPassword {
                    Section {
                        SecureField(bundle.loc("Current password"), text: $viewModel.currentPassword)
                    } header: {
                        Text("Current password", bundle: bundle)
                    }
                }

                Section {
                    SecureField(bundle.loc("New password (at least 8 characters)"), text: $viewModel.newPassword)
                    SecureField(bundle.loc("Confirm new password"), text: $viewModel.confirmPassword)
                } header: {
                    Text("New password", bundle: bundle)
                } footer: {
                    if !viewModel.hasPassword {
                        Text("Set a password to also sign in without Google.", bundle: bundle)
                    } else if viewModel.passwordsMismatch {
                        Text("Passwords do not match", bundle: bundle)
                            .foregroundColor(.red)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(bundle.loc(viewModel.hasPassword ? "Change password" : "Set password"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConfirmCancelButton { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            guard await viewModel.save(token: appState.authToken) else { return }
                            // A Google account may have just set its first password.
                            appState.currentUser?.hasPassword = true
                            showSuccess = true
                        }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save", bundle: bundle).fontWeight(.semibold)
                        }
                    }
                    .disabled(!viewModel.canSave)
                }
            }
            .alert(bundle.loc("Password changed"), isPresented: $showSuccess) {
                Button(bundle.loc("OK")) { dismiss() }
            }
        }
    }
}
