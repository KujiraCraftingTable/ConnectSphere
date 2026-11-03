import PhotosUI
import SwiftUI

/// Create a company page (you become its owner) or edit one you run.
struct CompanyEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: CompanyEditorViewModel
    @State private var logoItem: PhotosPickerItem?
    @State private var coverItem: PhotosPickerItem?
    let onSaved: (Company) -> Void

    init(editing: Company? = nil, onSaved: @escaping (Company) -> Void) {
        _viewModel = State(initialValue: CompanyEditorViewModel(editing: editing))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $logoItem, matching: .images, preferredItemEncoding: .current) {
                        Label(bundle.loc(viewModel.newLogo == nil ? "Choose logo" : "Logo chosen"), systemImage: "app.badge")
                    }
                    PhotosPicker(selection: $coverItem, matching: .images, preferredItemEncoding: .current) {
                        Label(bundle.loc(viewModel.newCover == nil ? "Choose cover photo" : "Cover photo chosen"), systemImage: "photo")
                    }
                }
                Section(bundle.loc("Company")) {
                    TextField(bundle.loc("Company name"), text: $viewModel.name)
                        .textInputAutocapitalization(.words)
                    TextField(bundle.loc("Industry (e.g. Software)"), text: $viewModel.industry)
                    Picker(bundle.loc("Company size"), selection: $viewModel.size) {
                        Text("Not set", bundle: bundle).tag("")
                        ForEach(Company.sizes, id: \.self) { Text(String(format: bundle.loc("%@ employees"), $0)).tag($0) }
                    }
                    TextField(bundle.loc("Website"), text: $viewModel.website)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LocationSearchField(bundle.loc("Headquarters"), text: $viewModel.headquarters)
                    TextField(bundle.loc("Founded (year)"), text: $viewModel.foundedYear)
                        .keyboardType(.numberPad)
                }
                Section(bundle.loc("About")) {
                    TextField(bundle.loc("What the company does, its culture…"), text: $viewModel.about, axis: .vertical)
                        .lineLimit(4...10)
                }
                if viewModel.editing == nil {
                    Section {
                        Text("You'll run this page. It shows as Official once it's verified.", bundle: bundle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(bundle.loc(viewModel.editing == nil ? "New company page" : "Edit page"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button(bundle.loc(viewModel.editing == nil ? "Create" : "Save")) {
                            Task {
                                guard let saved = await viewModel.save(token: appState.authToken ?? "") else { return }
                                onSaved(saved)
                                dismiss()
                            }
                        }
                        .disabled(!viewModel.canSave)
                    }
                }
            }
            .onChange(of: logoItem) { _, item in
                Task { viewModel.newLogo = try? await item?.loadTransferable(type: Data.self) }
            }
            .onChange(of: coverItem) { _, item in
                Task { viewModel.newCover = try? await item?.loadTransferable(type: Data.self) }
            }
        }
    }
}
