import SwiftUI

/// A 6-digit code field (paste / autofill friendly). The hint is in the
/// normal size so it's never cut off; typed digits are large and spaced.
struct CodeField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @Binding var code: String

    var body: some View {
        TextField("", text: $code)
            .placeholder(when: code.isEmpty) {
                Text(title).foregroundColor(AppColors.textTertiary(colorScheme)).font(.system(size: 16))
            }
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(code.isEmpty ? .system(size: 16) : .system(size: 22, weight: .semibold, design: .monospaced))
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

/// Settings › Account › Email: your verified email — and, from there,
/// changing it (confirm with the current address, then verify the new one).
/// Without a verified email it goes straight to adding one.
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
    private var current: String { appState.currentUser?.email ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.stage {
                case .overview: overview
                case .confirmCurrent: confirmCurrent
                case .newEmail: newEmail
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.system(size: 14)) }
                }
            }
            .animation(.snappy, value: viewModel.stage)
            .navigationTitle(bundle.loc("Email"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc(viewModel.stage == .overview ? "Done" : "Cancel")) { dismiss() }
                }
            }
        }
    }

    private var overview: some View {
        Section {
            HStack {
                Text(current).lineLimit(1)
                Spacer()
                Label(bundle.loc("Verified"), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Button(bundle.loc("Change email")) { viewModel.startChange() }
        } footer: {
            Text("You sign in with this email, and security codes are sent to it.", bundle: bundle)
        }
    }

    private var confirmCurrent: some View {
        Section {
            if !viewModel.currentSent {
                Button(String(format: bundle.loc("Send a code to %@"), AccountCode.mask(current))) {
                    Task { await viewModel.sendCurrentCode(token: token) }
                }
                .disabled(viewModel.isSending)
            } else {
                CodeField(title: bundle.loc("6-digit code"), code: $viewModel.currentCode)
                ResendButton(availableAt: viewModel.currentResendAt, isSending: viewModel.isSending) {
                    Task { await viewModel.sendCurrentCode(token: token) }
                }
                Button {
                    Task { await viewModel.confirmCurrent(token: token) }
                } label: {
                    HStack {
                        Text("Confirm", bundle: bundle).fontWeight(.semibold)
                        if viewModel.isVerifying { Spacer(); ProgressView() }
                    }
                }
                .disabled(!viewModel.canConfirmCurrent)
            }
        } header: {
            Text("Step 1 of 2 · Confirm it's you", bundle: bundle)
        } footer: {
            Text(String(format: bundle.loc("To change your email, first enter the code we send to %@ — so nobody else can take over your account."),
                        AccountCode.mask(current)))
        }
    }

    private var newEmail: some View {
        Section {
            TextField(bundle.loc("New email"), text: $viewModel.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(viewModel.sentTo != nil)
            if viewModel.sentTo == nil {
                Button(bundle.loc("Send code")) { Task { await viewModel.sendCode(token: token) } }
                    .disabled(viewModel.email.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSending)
            } else {
                CodeField(title: bundle.loc("6-digit code"), code: $viewModel.code)
                ResendButton(availableAt: viewModel.resendAt, isSending: viewModel.isSending) {
                    Task { await viewModel.sendCode(token: token) }
                }
                Button {
                    Task {
                        if let email = await viewModel.verify(token: token) {
                            onVerified(email)
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        Text("Verify", bundle: bundle).fontWeight(.semibold)
                        if viewModel.isVerifying { Spacer(); ProgressView() }
                    }
                }
                .disabled(!viewModel.canVerify)
            }
        } header: {
            Text(current.isEmpty || !(appState.currentUser?.emailVerified ?? false)
                 ? bundle.loc("Your email") : bundle.loc("Step 2 of 2 · Your new email"))
        } footer: {
            if let sent = viewModel.sentTo {
                Text(String(format: bundle.loc("We sent a code to %@. It expires in 10 minutes."), sent))
            } else {
                Text("We'll send a 6-digit code to check it's yours. It's used to confirm important changes like deleting your account.", bundle: bundle)
            }
        }
    }
}
