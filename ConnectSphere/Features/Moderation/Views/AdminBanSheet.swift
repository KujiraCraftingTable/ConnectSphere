import SwiftUI

/// The official account's Warn / Ban sheet, opened from a post, comment,
/// message or profile in place of Report. A third warning has to be a ban.
struct AdminBanSheet: View {
    @State private var viewModel: AdminBanViewModel
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    init(target: ModerationTarget) { _viewModel = State(initialValue: AdminBanViewModel(target: target)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(bundle.loc("Action"), selection: $viewModel.action) {
                        Text("Warn", bundle: bundle).tag(AdminBanViewModel.Action.warn)
                        Text("Ban", bundle: bundle).tag(AdminBanViewModel.Action.ban)
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.mustBan)
                } header: {
                    Text(viewModel.target.userName)
                } footer: {
                    if let n = viewModel.activeWarnings {
                        Text(viewModel.mustBan
                             ? String(format: bundle.loc("%lld of 3 warnings already: this one has to be a ban."), n)
                             : String(format: bundle.loc("%lld of 3 warnings in this profile. A third warning means a ban."), n))
                    }
                }

                Section {
                    Picker(bundle.loc("Reason"), selection: $viewModel.reason) {
                        ForEach(AdminBanViewModel.reasons, id: \.self) { r in
                            Text(bundle.loc(r.displayName)).tag(r)
                        }
                    }
                    if viewModel.action == .ban {
                        Picker(bundle.loc("How long"), selection: $viewModel.days) {
                            ForEach(AdminBanViewModel.durations, id: \.self) { d in
                                Text(d.map { String(format: bundle.loc("%lld days"), $0) } ?? bundle.loc("Permanently")).tag(d)
                            }
                        }
                    }
                    TextField(bundle.loc("Note for them (optional)"), text: $viewModel.note, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text(viewModel.action == .ban
                         ? bundle.loc("They're told why by notification and email, and can ask for a review.")
                         : bundle.loc("They're told why by notification and email. Three warnings within 90 days means a ban."))
                }

                if let err = viewModel.errorMessage {
                    Section { Text(err).foregroundColor(AppColors.danger(colorScheme)) }
                }
            }
            .navigationTitle(Text(viewModel.action == .ban ? "Ban" : "Warn", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton(hasChanges: !viewModel.note.isEmpty) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc(viewModel.action == .ban ? "Ban" : "Warn")) { confirming = true }
                        .disabled(viewModel.isSending)
                        .tint(viewModel.action == .ban ? AppColors.danger(colorScheme) : themeManager.theme.primary)
                        .confirmationDialog(confirmQuestion, isPresented: $confirming, titleVisibility: .visible) {
                            Button(bundle.loc(viewModel.action == .ban ? "Ban" : "Warn"), role: .destructive) {
                                Task { await viewModel.submit() }
                            }
                            Button(bundle.loc("Cancel"), role: .cancel) {}
                        } message: {
                            Text(bundle.loc(viewModel.reason.displayName))
                        }
                }
            }
            .task { await viewModel.load() }
            .onChange(of: viewModel.done) { _, done in if done != nil { dismiss() } }
        }
    }

    /// "Warn Linh?" / "Ban Linh for 30 days?" / "Ban Linh permanently?"
    private var confirmQuestion: String {
        let name = viewModel.target.userName
        guard viewModel.action == .ban else { return String(format: bundle.loc("Warn %@?"), name) }
        if let days = viewModel.days { return String(format: bundle.loc("Ban %@ for %lld days?"), name, days) }
        return String(format: bundle.loc("Ban %@ permanently?"), name)
    }
}
