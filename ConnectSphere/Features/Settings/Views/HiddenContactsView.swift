import SwiftUI

/// Settings › Privacy › Hidden contacts: people hidden from the Messages
/// people row in the current mode. "Unhide" acts at once, with a toast.
struct HiddenContactsView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(UndoToastPresenter.self) private var toastPresenter
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var viewModel = HiddenContactsViewModel()

    private var mode: String { appState.currentMode.rawValue }
    private var token: String { appState.authToken ?? "" }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.contacts.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError = viewModel.loadError, viewModel.contacts.isEmpty {
                errorState(loadError)
            } else if viewModel.contacts.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(viewModel.contacts) { contact in
                            row(contact)
                                .listRowBackground(AppColors.surface(colorScheme))
                        }
                    } footer: {
                        Text("People you hide leave the row at the top of Messages. Their chats stay.", bundle: bundle)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .animation(.default, value: viewModel.contacts.map(\.id))
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Hidden contacts"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(mode: mode, token: token) }
        .refreshable { await viewModel.load(mode: mode, token: token) }
        .alert(viewModel.actionError ?? "", isPresented: Binding(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button(bundle.loc("OK")) {}
        }
    }

    private func row(_ contact: HiddenContact) -> some View {
        HStack(spacing: 12) {
            Avatar(name: contact.displayName, colorHex: contact.avatarColor,
                   imageURL: contact.avatarUrl, diameter: 44)
            Text(contact.displayName)
                .scaledFont(15, .semibold)
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(1)
            Spacer()
            Button {
                Task {
                    guard await viewModel.unhide(contact, mode: mode, token: token) else { return }
                    toastPresenter.show(message: String(format: bundle.loc("%@ is back in Messages"), contact.displayName),
                                        edge: .top)
                }
            } label: {
                Text("Unhide", bundle: bundle)
                    .scaledFont(13, .semibold)
                    .foregroundColor(themeManager.theme.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(themeManager.theme.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .scaledFont(40)
                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.4))
            Text("No hidden contacts", bundle: bundle)
                .scaledFont(15)
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .scaledFont(38)
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text(message)
                .scaledFont(14)
                .multilineTextAlignment(.center)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .padding(.horizontal, 32)
            Button(bundle.loc("Retry")) { Task { await viewModel.load(mode: mode, token: token) } }
                .scaledFont(14, .semibold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
