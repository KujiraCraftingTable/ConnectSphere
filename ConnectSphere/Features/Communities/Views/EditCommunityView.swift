import SwiftUI
import PhotosUI

/// "..." › Edit community (admins and moderators).
struct EditCommunityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: EditCommunityViewModel
    @State private var pickerItem: PhotosPickerItem?
    let onSaved: (Community) -> Void

    init(community: Community, onSaved: @escaping (Community) -> Void) {
        _viewModel = State(initialValue: EditCommunityViewModel(community: community))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    coverPreview
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        HStack(spacing: 12) {
                            Image(systemName: "photo").frame(width: 24)
                            Text(viewModel.original.coverUrl == nil && viewModel.pickedCover == nil
                                 ? bundle.loc("Add cover photo") : bundle.loc("Change cover photo"))
                        }
                    }
                    if viewModel.pickedCover != nil || viewModel.showsExistingCover {
                        Button(role: .destructive) { viewModel.clearCover() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "trash").frame(width: 24)
                                Text("Remove cover photo", bundle: bundle)
                            }
                            .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Cover photo", bundle: bundle)
                }

                Section {
                    TextField(bundle.loc("Name"), text: $viewModel.name)
                    if let problem = viewModel.nameProblem {
                        Text(problem).font(.system(size: 13)).foregroundStyle(.red)
                    }
                } header: {
                    Text("Name", bundle: bundle)
                }

                Section {
                    TextEditor(text: $viewModel.about).frame(minHeight: 100)
                } header: {
                    Text("About", bundle: bundle)
                } footer: {
                    Text("\(viewModel.about.count)/\(EditCommunityViewModel.maxAbout)")
                }

                Section {
                    Picker(bundle.loc("Privacy"), selection: $viewModel.privacy) {
                        Text("Public", bundle: bundle).tag(CommunityPrivacy.public)
                        Text("Private", bundle: bundle).tag(CommunityPrivacy.private)
                    }
                    Toggle(bundle.loc("Approve member posts"), isOn: $viewModel.requirePostApproval)
                } footer: {
                    Text("When on, members' posts wait for an admin or moderator to approve them before anyone else sees them.", bundle: bundle)
                }

                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(bundle.loc("Edit community"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(bundle.loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Save")) {
                            Task {
                                if let saved = await viewModel.save(token: appState.authToken ?? "") {
                                    onSaved(saved)
                                    dismiss()
                                }
                            }
                        }
                        .disabled(viewModel.nameProblem != nil)
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await viewModel.loadCover(from: item) }
            }
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        if let picked = viewModel.pickedCover {
            Image(uiImage: picked).resizable().scaledToFill()
        } else {
            CommunityCover(community: viewModel.original, emojiSize: 44, showsPhoto: viewModel.showsExistingCover)
        }
    }
}
