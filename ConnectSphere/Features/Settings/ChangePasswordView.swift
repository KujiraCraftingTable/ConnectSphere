import SwiftUI

/// Changes an existing password, or sets one for the first time (Google account).
/// Opened from Privacy & Security.
struct ChangePasswordView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showSuccess = false

    private var hasPassword: Bool { appState.currentUser?.hasPassword ?? true }

    private var canSave: Bool {
        (!hasPassword || !currentPassword.isEmpty)
            && newPassword.count >= 8
            && newPassword == confirmPassword
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                if hasPassword {
                    Section {
                        SecureField(bundle.loc("Current password"), text: $currentPassword)
                    } header: {
                        Text("Current password", bundle: bundle)
                    }
                }

                Section {
                    SecureField(bundle.loc("New password (at least 8 characters)"), text: $newPassword)
                    SecureField(bundle.loc("Confirm new password"), text: $confirmPassword)
                } header: {
                    Text("New password", bundle: bundle)
                } footer: {
                    if !hasPassword {
                        Text("Set a password to also sign in without Google.", bundle: bundle)
                    } else if !confirmPassword.isEmpty && newPassword != confirmPassword {
                        Text("Passwords do not match", bundle: bundle)
                            .foregroundColor(.red)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(bundle.loc(hasPassword ? "Change password" : "Set password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save", bundle: bundle).fontWeight(.semibold)
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .alert(bundle.loc("Password changed"), isPresented: $showSuccess) {
                Button(bundle.loc("OK")) { dismiss() }
            }
        }
    }

    private func save() async {
        guard let token = appState.authToken else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await AuthService.shared.changePassword(
                token: token,
                currentPassword: hasPassword ? currentPassword : nil,
                newPassword: newPassword
            )
            // Google account just set a password for the first time → update local state
            appState.currentUser?.hasPassword = true
            showSuccess = true
        } catch {
            errorMessage = (error as NSError).code == 401
                ? bundle.loc("Current password is incorrect")
                : bundle.loc("Couldn't change password, please try again")
        }
    }
}
