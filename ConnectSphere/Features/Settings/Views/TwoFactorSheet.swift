import SwiftUI

/// Turning two-factor sign-in on or off: what it does, then a code from the
/// verified email to confirm.
struct TwoFactorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: TwoFactorViewModel

    init(enabling: Bool) { _viewModel = State(initialValue: TwoFactorViewModel(enabling: enabling)) }

    private var token: String { appState.authToken ?? "" }
    private var email: String { appState.currentUser?.email ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(bundle.loc(viewModel.enabling
                            ? "Every time you sign in, with your password or Google, we'll email a 6-digit code you need to enter. Someone who knows your password still can't get in."
                            : "You'll sign in without a code again. You'll still get an email each time your account is signed in to."))
                    } icon: {
                        Image(systemName: viewModel.enabling ? "lock.shield.fill" : "lock.open.fill")
                    }
                    .font(.system(size: 15))
                }
                Section {
                    if viewModel.sentTo == nil {
                        Button(String(format: bundle.loc("Send a code to %@"), AccountCode.mask(email))) {
                            Task { await viewModel.sendCode(token: token) }
                        }
                        .disabled(viewModel.isWorking || email.isEmpty)
                    } else {
                        CodeEntry(code: $viewModel.code,
                                  confirmTitle: bundle.loc(viewModel.enabling ? "Turn on" : "Turn off"),
                                  confirmIsDestructive: !viewModel.enabling,
                                  canConfirm: viewModel.canConfirm, isWorking: viewModel.isWorking,
                                  onConfirm: { Task { if await viewModel.confirm(appState: appState) { dismiss() } } },
                                  resendAt: viewModel.resendAt, isSending: viewModel.isWorking,
                                  onResend: { Task { await viewModel.sendCode(token: token) } })
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                } header: {
                    Text("Confirm with your email", bundle: bundle)
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.system(size: 14)) }
                }
            }
            .navigationTitle(bundle.loc("Two-factor authentication"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!viewModel.code.isEmpty)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { ConfirmCancelButton(hasChanges: !viewModel.code.isEmpty) { dismiss() } }
            }
        }
    }
}
