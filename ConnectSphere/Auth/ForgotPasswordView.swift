import SwiftUI

/// Forgot password — 2 steps in a single sheet:
/// (1) enter username/email to receive a code, (2) enter the 6-digit OTP + new password.
/// The dev environment has no SMTP set up yet, so the OTP is printed to the server log.
struct ForgotPasswordView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case requestCode, resetPassword, done
    }

    @State private var step: Step = .requestCode
    @State private var identifier = ""
    @State private var otp = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .requestCode:  requestCodeSection
                case .resetPassword: resetSection
                case .done:          doneSection
                }

                if let errorMessage {
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
            TextField(bundle.loc("Username or email"), text: $identifier)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await sendCode() }
            } label: {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Send code", bundle: bundle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(identifier.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
        } footer: {
            Text("If the account has an email on file, a 6-digit code has been sent.", bundle: bundle)
        }
    }

    // MARK: - Step 2: OTP + new password

    private var resetSection: some View {
        Section {
            TextField(bundle.loc("Verification code"), text: $otp)
                .keyboardType(.numberPad)
            SecureField(bundle.loc("New password (at least 8 characters)"), text: $newPassword)
            SecureField(bundle.loc("Confirm new password"), text: $confirmPassword)

            Button {
                Task { await resetPassword() }
            } label: {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Reset password", bundle: bundle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!canReset)
        } footer: {
            if !confirmPassword.isEmpty && newPassword != confirmPassword {
                Text("Passwords do not match", bundle: bundle)
                    .foregroundColor(.red)
            } else {
                Text("If the account has an email on file, a 6-digit code has been sent.", bundle: bundle)
            }
        }
    }

    private var canReset: Bool {
        otp.trimmingCharacters(in: .whitespaces).count == 6
            && newPassword.count >= 8
            && newPassword == confirmPassword
            && !isLoading
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

    // MARK: - Actions

    private func sendCode() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.forgotPassword(
                identifier: identifier.trimmingCharacters(in: .whitespaces)
            )
            step = .resetPassword
        } catch {
            errorMessage = bundle.loc("Couldn't send code, please try again")
        }
    }

    private func resetPassword() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.resetPassword(
                identifier: identifier.trimmingCharacters(in: .whitespaces),
                otp: otp.trimmingCharacters(in: .whitespaces),
                newPassword: newPassword
            )
            step = .done
        } catch {
            errorMessage = (error as NSError).code == 401
                ? bundle.loc("Invalid or expired code")
                : bundle.loc("Couldn't reset password, please try again")
        }
    }
}
