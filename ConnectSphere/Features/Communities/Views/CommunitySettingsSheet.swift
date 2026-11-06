import SwiftUI

/// "..." › Community settings: pin, hide from feed, report, leave.
struct CommunitySettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    let viewModel: CommunityDetailViewModel
    /// Left the community. The page closes too.
    let onLeft: () -> Void
    @State private var showReport = false
    @State private var confirmLeave = false

    private var community: Community? { viewModel.community }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { community?.isPinned ?? false },
                                         set: { on in Task { await viewModel.setPinned(on) } })) {
                        row("pin", bundle.loc("Pin to top of My communities"))
                    }
                    Toggle(isOn: Binding(get: { community?.isMuted ?? false },
                                         set: { on in Task { await viewModel.setHiddenFromFeed(on) } })) {
                        row("eye.slash", bundle.loc("Hide posts from my feed"))
                    }
                } footer: {
                    Text("Hidden posts still show here in the community.", bundle: bundle)
                }
                Section {
                    Button { showReport = true } label: { row("flag", bundle.loc("Report community")) }
                        .buttonStyle(.plain)
                    Button(role: .destructive) { confirmLeave = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 24)
                            Text("Leave community", bundle: bundle)
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(bundle.loc("Community settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(bundle.loc("Done")) { dismiss() } }
            }
            .sheet(isPresented: $showReport) {
                ReportSheet(targetType: "community", targetId: community?.id ?? "",
                            communityId: community?.id ?? "", token: appState.authToken ?? "")
            }
            .confirmationDialog(bundle.loc("Leave this community?"), isPresented: $confirmLeave, titleVisibility: .visible) {
                Button(bundle.loc("Leave community"), role: .destructive) {
                    Task {
                        if await viewModel.leave() {
                            dismiss()
                            onLeft()
                        }
                    }
                }
            } message: {
                Text("You'll stop seeing its posts. You can join again later.", bundle: bundle)
            }
            .alert(bundle.loc("Error"), isPresented: Binding(
                get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button(bundle.loc("OK")) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Plain HStack: Label text disappears inside Form rows.
    private func row(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24)
            Text(title)
        }
    }
}
