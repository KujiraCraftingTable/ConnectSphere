import SwiftUI
import PhotosUI

/// Profile-editing sheet — name, bio, job, location, and profile picture.
/// Saves via PATCH /api/users/me, then updates appState.currentUser.
struct EditProfileView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    var onSaved: ((UserProfile) -> Void)? = nil

    @State private var viewModel = EditProfileViewModel()

    @State private var pickerItem: PhotosPickerItem?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var showCoverPicker = false
    @State private var showCoverCrop = false
    @State private var showCoverOptions = false

    var body: some View {
        NavigationStack {
            Form {
                // ── Cover photo ──────────────────────────────────────────────
                Section(bundle.loc("Cover photo")) {
                    Button {
                        // A photo picked this session can be re-framed; otherwise
                        // go straight to choosing one.
                        if viewModel.coverOriginal != nil { showCoverOptions = true } else { showCoverPicker = true }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            coverPreview
                            ZStack {
                                Circle().fill(themeManager.theme.primary)
                                    .frame(width: 28, height: 28)
                                // Pencil once there's a cover to edit; camera to add the first one.
                                Image(systemName: hasCover ? "pencil" : "camera.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(8)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .accessibilityLabel(Text(hasCover ? "Edit cover photo" : "Add cover photo", bundle: bundle))
                    // On the cover itself, so the choices point at it.
                    .confirmationDialog(bundle.loc("Cover photo"), isPresented: $showCoverOptions) {
                        Button(bundle.loc("Adjust position")) { showCoverCrop = true }
                        Button(bundle.loc("Choose new photo")) { showCoverPicker = true }
                        Button(bundle.loc("Cancel"), role: .cancel) {}
                    }
                }

                // ── Avatar ────────────────────────────────────────────────────
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                avatarPreview
                                ZStack {
                                    Circle().fill(themeManager.theme.primary)
                                        .frame(width: 28, height: 28)
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                // ── Basic info ─────────────────────────────────────────
                Section(bundle.loc("About")) {
                    HStack {
                        TextField(bundle.loc("Display name"), text: $viewModel.displayName)
                        CharacterCounter(count: viewModel.displayName.count, limit: DisplayNameRules.maxLength)
                    }
                    TextField(bundle.loc("About yourself"), text: $viewModel.bio, axis: .vertical)
                        .lineLimit(3...5)
                    TextField(bundle.loc("Location"), text: $viewModel.location)
                    DatePicker(bundle.loc("Date of birth"), selection: $viewModel.dobDate,
                               displayedComponents: .date)

                    DobVisibilityToggle(
                        visibility: $viewModel.dobVisibility,
                        accentColor: themeManager.theme.primary,
                        colorScheme: colorScheme
                    )
                    .padding(.vertical, 4)
                }

                // ── Interests / Skills — based on the current mode, same as onboarding ─
                if appState.currentMode == .hobby {
                    Section(bundle.loc("Interests")) {
                        InterestPickerView(selectedInterests: $viewModel.selectedInterests, colorScheme: colorScheme)
                            .padding(.vertical, 4)
                    }
                }

                Section(bundle.loc("Work")) {
                    TextField(bundle.loc("Job title"), text: $viewModel.jobTitle)
                    TextField(bundle.loc("Company"), text: $viewModel.company)
                    if appState.currentMode == .work {
                        SkillTagField(skills: $viewModel.skills, colorScheme: colorScheme)
                            .padding(.vertical, 4)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(bundle.loc("Edit profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            guard let updated = await viewModel.save(mode: appState.currentMode) else { return }
                            appState.currentUser = updated
                            onSaved?(updated)
                            dismiss()
                        }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save", bundle: bundle).fontWeight(.semibold)
                        }
                    }
                    .disabled(!viewModel.canSave)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await viewModel.loadAvatar(from: item) }
            }
            .photosPicker(isPresented: $showCoverPicker, selection: $coverPickerItem, matching: .images)
            .onChange(of: coverPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if await viewModel.loadCover(from: item) { showCoverCrop = true }
                    // Cleared so picking the same photo again still fires.
                    coverPickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCoverCrop) {
                if let coverOriginal = viewModel.coverOriginal {
                    CoverCropView(image: coverOriginal) { viewModel.pickedCover = $0 }
                        .environment(themeManager)
                }
            }
            .onAppear { viewModel.load(from: appState.currentUser) }
        }
    }

    // MARK: - Cover preview

    private var hasCover: Bool {
        viewModel.pickedCover != nil || !(appState.currentUser?.coverUrl ?? "").isEmpty
    }

    /// Same shape as the profile's cover, so the preview is what the profile shows.
    @ViewBuilder
    private var coverPreview: some View {
        if let pickedCover = viewModel.pickedCover {
            Color.clear
                .aspectRatio(CoverPhotoView.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { Image(uiImage: pickedCover).resizable().scaledToFill() }
                .clipped()
        } else {
            CoverPhotoView(coverUrl: appState.currentUser?.coverUrl)
        }
    }

    // MARK: - Avatar preview

    @ViewBuilder
    private var avatarPreview: some View {
        if let pickedImage = viewModel.pickedImage {
            Image(uiImage: pickedImage)
                .resizable()
                .scaledToFill()
                .frame(width: 90, height: 90)
                .clipShape(Circle())
        } else if let user = appState.currentUser {
            AvatarView(user: user, size: 90)
        }
    }
}
