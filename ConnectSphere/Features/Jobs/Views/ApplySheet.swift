import SwiftUI
import UniformTypeIdentifiers

/// Easy Apply: your Work profile goes with it; add a note and a PDF CV if
/// you like.
struct ApplySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let job: JobListing
    let onApplied: (JobApplication) -> Void
    @State private var viewModel: ApplyViewModel
    @State private var pickingCV = false
    /// A note typed or a CV attached. Closing would lose it.
    private var hasInput: Bool {
        !viewModel.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.cvUrl != nil
    }

    init(job: JobListing, onApplied: @escaping (JobApplication) -> Void) {
        self.job = job
        self.onApplied = onApplied
        _viewModel = State(initialValue: ApplyViewModel(jobId: job.id))
    }

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.title).font(.system(size: 17, weight: .semibold))
                        Text(job.companyName ?? job.poster.displayName)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
                Section {
                    if let me = appState.currentUser {
                        HStack(spacing: 12) {
                            Avatar(name: me.name, colorHex: me.avatarColor, imageURL: me.avatarUrl, size: .md)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(me.name).font(.system(size: 15, weight: .semibold))
                                if let title = me.jobTitle, !title.isEmpty {
                                    Text(title).font(.system(size: 13)).foregroundColor(AppColors.textSecondary(colorScheme))
                                }
                            }
                        }
                    }
                } header: {
                    Text("Your profile", bundle: bundle)
                } footer: {
                    Text("Your Work profile, experience and skills, is shared with the job's poster.", bundle: bundle)
                }
                Section {
                    TextField(bundle.loc("Why you're a good fit (optional)"), text: $viewModel.note, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("Note", bundle: bundle)
                } footer: {
                    if viewModel.noteTooLong {
                        Text(String(format: bundle.loc("Keep it under %lld characters."), ApplyViewModel.noteLimit))
                            .foregroundColor(.red)
                    }
                }
                Section {
                    if let name = viewModel.cvName {
                        HStack {
                            Label(name, systemImage: "doc.richtext").lineLimit(1)
                            Spacer()
                            Button(role: .destructive) { viewModel.removeCV() } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundColor(AppColors.textTertiary(colorScheme))
                                .accessibilityLabel(Text(bundle.loc("Remove")))
                        }
                    } else if viewModel.isUploadingCV {
                        HStack { ProgressView(); Text("Uploading…", bundle: bundle) }
                    } else {
                        Button { pickingCV = true } label: { Label(bundle.loc("Attach a CV (PDF)"), systemImage: "paperclip") }
                    }
                } header: {
                    Text("CV", bundle: bundle)
                } footer: {
                    Text("Optional. PDF, up to 10 MB. Only the people hiring can open it.", bundle: bundle)
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundColor(.red).font(.system(size: 14)) }
                }
            }
            .navigationTitle(bundle.loc("Apply"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasInput)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton(hasChanges: hasInput) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSubmitting {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Send")) {
                            Task {
                                if let application = await viewModel.submit(token: token) {
                                    onApplied(application)
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!viewModel.canSubmit)
                    }
                }
            }
            .fileImporter(isPresented: $pickingCV, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result {
                    Task { await viewModel.attachCV(at: url, token: token) }
                }
            }
        }
    }
}
