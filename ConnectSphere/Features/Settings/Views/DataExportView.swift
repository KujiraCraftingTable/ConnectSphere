import SwiftUI

/// Settings › Manage account › Download my data. The file holds everything about
/// the person, so it is released only after a code sent to their verified email
/// (or their password when the account has no verified email).
struct DataExportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @State private var viewModel: DataExportViewModel

    init(hasVerifiedEmail: Bool) {
        _viewModel = State(initialValue: DataExportViewModel(hasVerifiedEmail: hasVerifiedEmail))
    }

    private var token: String? { appState.authToken }

    var body: some View {
        List {
            Section {
                if let file = viewModel.file {
                    ShareLink(item: file) {
                        SettingsRowLabel(icon: "square.and.arrow.up", label: bundle.loc("Save or share your data file"),
                                         color: Color(hex: "#2196F3"), showsChevron: false)
                    }
                } else if viewModel.usesPassword {
                    SecureField(bundle.loc("Password"), text: $viewModel.password)
                    Button(bundle.loc("Download my data")) { Task { await viewModel.download(token: token) } }
                        .disabled(!viewModel.canDownload)
                } else if viewModel.sentTo == nil {
                    Button(String(format: bundle.loc("Send a code to %@"), AccountCode.mask(appState.currentUser?.email ?? ""))) {
                        Task { await viewModel.sendCode(token: token) }
                    }
                    .disabled(viewModel.isSending)
                } else {
                    CodeEntry(code: $viewModel.code, confirmTitle: bundle.loc("Download my data"),
                              canConfirm: viewModel.canDownload, isWorking: viewModel.isLoading,
                              onConfirm: { Task { await viewModel.download(token: token) } },
                              resendAt: viewModel.resendAt, isSending: viewModel.isSending,
                              onResend: { Task { await viewModel.sendCode(token: token) } })
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            } header: {
                Text(viewModel.usesPassword ? bundle.loc("Confirm with your password") : bundle.loc("Confirm with your email"))
            } footer: {
                if let sent = viewModel.sentTo, viewModel.file == nil {
                    Text(String(format: bundle.loc("We sent a code to %@. It expires in 10 minutes."), AccountCode.mask(sent)))
                } else {
                    Text("A file with your profile, posts, comments, messages you sent and other data we hold about you.", bundle: bundle)
                }
            }
            if let message = viewModel.errorMessage {
                Section { Text(message).foregroundStyle(.red).scaledFont(14) }
            }
        }
        .navigationTitle(bundle.loc("Download my data"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
