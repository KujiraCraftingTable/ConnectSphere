import SwiftUI

/// A 6-digit code field (paste / autofill friendly).
struct CodeField: View {
    @Environment(\.appBundle) private var bundle
    let title: String
    @Binding var code: String

    var body: some View {
        TextField(title, text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .accessibilityLabel(Text(title))
    }
}

/// "Resend code" that waits out the server's one-a-minute limit.
struct ResendButton: View {
    @Environment(\.appBundle) private var bundle
    let availableAt: Date?
    let isSending: Bool
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = AccountCode.secondsLeft(until: availableAt, now: context.date)
            Button(left > 0 ? String(format: bundle.loc("Resend code in %llds"), left) : bundle.loc("Resend code"), action: action)
                .disabled(left > 0 || isSending)
                .font(.system(size: 14))
        }
    }
}

/// Settings › Account › Email: add an email, or replace the verified one.
struct EmailVerificationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EmailVerificationViewModel
    let onVerified: (String) -> Void

    init(replacingVerifiedEmail: Bool, onVerified: @escaping (String) -> Void) {
        _viewModel = State(initialValue: EmailVerificationViewModel(replacingVerifiedEmail: replacingVerifiedEmail))
        self.onVerified = onVerified
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.needsCurrentCode, let current = appState.currentUser?.email {
                    Section {
                        if viewModel.currentSentTo == nil {
                            Button(String(format: bundle.loc("Send a code to %@"), AccountCode.mask(current))) {
                                Task { await viewModel.sendCurrentCode(token: token) }
                            }
                            .disabled(viewModel.isSending)
                        } else {
                            CodeField(title: bundle.loc("Code from your current email"), code: $viewModel.currentCode)
                            ResendButton(availableAt: viewModel.currentResendAt, isSending: viewModel.isSending) {
                                Task { await viewModel.sendCurrentCode(token: token) }
                            }
                        }
                    } header: {
                        Text("1. Confirm it's you", bundle: bundle)
                    } footer: {
                        Text("Changing your email needs a code sent to the one you have now, so nobody else can take over your account.", bundle: bundle)
                    }
                }
                Section {
                    TextField(bundle.loc("New email"), text: $viewModel.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if viewModel.sentTo == nil {
                        Button(bundle.loc("Send code")) { Task { await viewModel.sendCode(token: token) } }
                            .disabled(viewModel.email.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSending)
                    } else {
                        CodeField(title: bundle.loc("6-digit code"), code: $viewModel.code)
                        ResendButton(availableAt: viewModel.resendAt, isSending: viewModel.isSending) {
                            Task { await viewModel.sendCode(token: token) }
                        }
                    }
                } header: {
                    Text(viewModel.needsCurrentCode ? bundle.loc("2. Your new email") : bundle.loc("Your email"))
                } footer: {
                    if let sent = viewModel.sentTo {
                        Text(String(format: bundle.loc("We sent a code to %@. It expires in 10 minutes."), sent))
                    } else {
                        Text("We'll send a 6-digit code to check it's yours. It's used to confirm important changes like deleting your account.", bundle: bundle)
                    }
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.system(size: 14)) }
                }
            }
            .navigationTitle(bundle.loc("Email"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isVerifying {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Verify")) {
                            Task {
                                if let email = await viewModel.verify(token: token) {
                                    onVerified(email)
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!viewModel.canVerify)
                    }
                }
            }
        }
    }
}
