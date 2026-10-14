import SwiftUI

/// Forgot password — 2 steps in a single sheet:
/// (1) enter username/email to receive a code, (2) enter the 6-digit OTP + new password.
/// The dev environment has no SMTP set up yet, so the OTP is printed to the server log.
struct ForgotPasswordView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = ForgotPasswordViewModel()

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.step {
                case .requestCode:  requestCodeSection
                case .resetPassword: resetSection
                case .done:          doneSection
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(bundle.loc("Reset password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
            }
        }
    }

    // MARK: - Step 1: request OTP

    private var requestCodeSection: some View {
        Section {
            TextField(bundle.loc("Username or email"), text: $viewModel.identifier)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await viewModel.sendCode() }
            } label: {
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Send code", bundle: bundle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!viewModel.canSendCode)
        } footer: {
            Text("If the account has an email on file, a 6-digit code has been sent.", bundle: bundle)
        }
    }

    // MARK: - Step 2: OTP + new password

    private var resetSection: some View {
        Section {
            TextField(bundle.loc("Verification code"), text: $viewModel.otp)
                .keyboardType(.numberPad)
            SecureField(bundle.loc("New password (at least 8 characters)"), text: $viewModel.newPassword)
            SecureField(bundle.loc("Confirm new password"), text: $viewModel.confirmPassword)

            Button {
                Task { await viewModel.resetPassword() }
            } label: {
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Reset password", bundle: bundle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!viewModel.canReset)
        } footer: {
            if viewModel.passwordsMismatch {
                Text("Passwords do not match", bundle: bundle)
                    .foregroundColor(.red)
            } else {
                Text("If the account has an email on file, a 6-digit code has been sent.", bundle: bundle)
            }
        }
    }

    // MARK: - Step 3: done

    private var doneSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.green)
                Text("Password reset. Please log in with your new password.", bundle: bundle)
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                Button {
                    dismiss()
                } label: {
                    Text("Done", bundle: bundle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

}
