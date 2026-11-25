import PhotosUI
import SwiftUI

/// "Edit marketplace profile": the name, photo, cover and bio buyers see on
/// your listings and seller page, apart from your normal profile.
struct EditMarketplaceProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EditMarketplaceProfileViewModel
    @State private var avatarItem: PhotosPickerItem?
    @State private var coverItem: PhotosPickerItem?
    @State private var showCoverPicker = false
    @State private var showCoverCrop = false
    @State private var confirmSave = false
    @State private var confirmDiscard = false
    private let onSaved: (SellerProfile) -> Void

    init(profile: SellerProfile, onSaved: @escaping (SellerProfile) -> Void) {
        _viewModel = State(initialValue: EditMarketplaceProfileViewModel(profile: profile))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Like Edit profile's cover: tap it (or its camera badge) to pick one.
                    Button { showCoverPicker = true } label: {
                        ZStack(alignment: .bottomTrailing) {
                            coverPreview
                            ZStack {
                                Circle().fill(themeManager.theme.primary).frame(width: 28, height: 28)
                                Image(systemName: "camera.fill").scaledFont(13).foregroundColor(.white)
                            }
                            .padding(8)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Choose cover photo", bundle: bundle))
                    .listRowInsets(EdgeInsets())
                    if viewModel.hasOwnCover {
                        Button(bundle.loc("Use my profile's cover"), role: .destructive) { viewModel.useProfileCover() }
                    }
                } header: {
                    Text("Cover photo", bundle: bundle)
                }

                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                avatarPreview
                                ZStack {
                                    Circle().fill(themeManager.theme.primary).frame(width: 28, height: 28)
                                    Image(systemName: "camera.fill").scaledFont(13).foregroundColor(.white)
                                }
                            }
                        }
                        .accessibilityLabel(Text("Change photo", bundle: bundle))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    if viewModel.hasOwnAvatar {
                        Button(bundle.loc("Use my profile photo"), role: .destructive) { viewModel.useProfileAvatar() }
                    }
                }

                Section {
                    HStack {
                        TextField(viewModel.profile.ownDisplayName == nil ? viewModel.profile.displayName
                                                                           : bundle.loc("Shop name"),
                                  text: $viewModel.name)
                        CharacterCounter(count: viewModel.name.count, limit: EditMarketplaceProfileViewModel.maxNameLength)
                    }
                    TextField(bundle.loc("What do you sell?"), text: $viewModel.bio, axis: .vertical)
                        .lineLimit(3...6)
                    CharacterCounter(count: viewModel.bio.count, limit: EditMarketplaceProfileViewModel.maxBioLength)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } header: {
                    Text("About your shop", bundle: bundle)
                } footer: {
                    Text("Only shows on your listings and seller page. Anything left empty uses your profile's.",
                         bundle: bundle)
                }

                if let error = viewModel.errorMessage {
                    Text(error).foregroundColor(AppColors.danger(colorScheme))
                }
            }
            .navigationTitle(Text("Edit marketplace profile", bundle: bundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) {
                        if viewModel.hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog(bundle.loc("Discard changes?"), isPresented: $confirmDiscard,
                                        titleVisibility: .visible) {
                        Button(bundle.loc("Discard changes"), role: .destructive) { dismiss() }
                        Button(bundle.loc("Keep editing"), role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button(bundle.loc("Save")) { confirmSave = true }
                            .fontWeight(.semibold)
                            .disabled(!viewModel.canSave)
                            // On the button itself, so the popover points at Save.
                            .confirmationDialog(bundle.loc("Save your marketplace profile?"), isPresented: $confirmSave,
                                                titleVisibility: .visible) {
                                Button(bundle.loc("Save")) {
                                    Task {
                                        if let saved = await viewModel.save(token: appState.authToken ?? "") {
                                            onSaved(saved)
                                            dismiss()
                                        }
                                    }
                                }
                                Button(bundle.loc("Cancel"), role: .cancel) {}
                            }
                    }
                }
            }
            // Swiping the sheet away would skip the Cancel check.
            .interactiveDismissDisabled(viewModel.hasChanges)
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task { await viewModel.loadAvatar(from: item) }
            }
            .photosPicker(isPresented: $showCoverPicker, selection: $coverItem, matching: .images)
            .onChange(of: coverItem) { _, item in
                guard let item else { return }
                Task {
                    if await viewModel.loadCover(from: item) { showCoverCrop = true }
                    // Cleared so picking the same photo again still fires.
                    coverItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCoverCrop) {
                if let original = viewModel.coverOriginal {
                    CoverCropView(image: original) { viewModel.pickedCover = $0 }
                        .environment(themeManager)
                }
            }
        }
    }

    // MARK: - Cover & photo previews
    @ViewBuilder
    private var coverPreview: some View {
        // The same frame as Edit profile and the seller page's cover.
        if let picked = viewModel.pickedCover {
            Color.clear
                .aspectRatio(CoverPhotoView.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { Image(uiImage: picked).resizable().scaledToFill() }
                .clipped()
        } else {
            // Their own cover, else the profile's it falls back to.
            CoverPhotoView(coverUrl: viewModel.coverUrl ?? viewModel.profile.profileCoverUrl)
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        if let picked = viewModel.pickedAvatar {
            Image(uiImage: picked).resizable().scaledToFill()
                .frame(width: 90, height: 90).clipShape(Circle())
        } else {
            // Their own marketplace photo, else the profile's it falls back to.
            Avatar(name: viewModel.profile.displayName, colorHex: viewModel.profile.avatarColor,
                   imageURL: viewModel.avatarUrl ?? viewModel.profile.profileAvatarUrl, diameter: 90)
        }
    }
}
