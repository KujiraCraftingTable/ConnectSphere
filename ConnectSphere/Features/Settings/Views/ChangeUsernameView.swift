import SwiftUI

/// Manage account › Username: pick a new @username, once every six months.
/// While the last change is recent, it says when the next one is allowed.
struct ChangeUsernameView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = ChangeUsernameViewModel()
    @State private var confirming = false
    @FocusState private var focused: Bool

    private var current: String { appState.currentUser?.username ?? "" }

    var body: some View {
        Form {
            Section {
                LabeledContent(bundle.loc("Current"), value: "@\(current)")
            }
            if let until = viewModel.lockedUntil(appState) {
                Section {
                    Label {
                        Text(String(format: bundle.loc("You can change your username again on %@."), day(until)))
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .scaledFont(15)
                }
            } else {
                Section {
                    HStack(spacing: 2) {
                        Text(verbatim: "@").foregroundStyle(.secondary)
                        TextField(bundle.loc("New username"), text: $viewModel.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.done)
                            .focused($focused)
                    }
                    if let status = statusText {
                        Text(status.text).scaledFont(13).foregroundStyle(status.color)
                    }
                } footer: {
                    Text("3-30 characters: lowercase letters, numbers and underscore. You can change it once every 6 months. Your old username stays reserved for you, and you'll sign in with the new one.", bundle: bundle)
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red).scaledFont(14) }
                }
            }
        }
        .navigationTitle(bundle.loc("Username"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.lockedUntil(appState) == nil {
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Save")) { focused = false; confirming = true }
                            .disabled(!viewModel.canSave)
                    }
                }
            }
        }
        .alert(String(format: bundle.loc("Change to @%@?"), viewModel.normalized), isPresented: $confirming) {
            Button(bundle.loc("Change username")) {
                Task { if await viewModel.save(appState: appState) { dismiss() } }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: bundle.loc("You won't be able to change it again until %@."), day(viewModel.nextChangeIfSavedNow)))
        }
        .onAppear { viewModel.start(appState: appState) }
    }

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(bundle.locale))
    }

    private var statusText: (text: String, color: Color)? {
        switch viewModel.availability {
        case .unknown: return nil
        case .checking: return (bundle.loc("Checking…"), .secondary)
        case .available: return (bundle.loc("Username available"), .green)
        case .taken: return (bundle.loc("Username already taken"), .red)
        case .invalid: return (bundle.loc("Username must be 3-30 characters: lowercase letters, numbers, underscore"), .red)
        case .same: return (bundle.loc("That's already your username"), .secondary)
        }
    }
}
