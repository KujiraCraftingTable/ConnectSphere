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
    @State private var confirmDobChange = false

    @State private var pickingLanguages = false

    @State private var schools = EducationListViewModel()

    @State private var editingSchool: SchoolTarget?

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
                    LocationSearchField(bundle.loc("Location"), text: $viewModel.location)
                    DatePicker(bundle.loc("Date of birth"), selection: $viewModel.dobDate,
                               displayedComponents: .date)
                        .disabled(viewModel.isDobLocked)
                    dobNote

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
                    Section {
                        Picker(bundle.loc("Relationship"), selection: $viewModel.relationship) {
                            Text("Not set", bundle: bundle).tag(RelationshipStatus?.none)
                            ForEach(RelationshipStatus.allCases) { Text(bundle.loc($0.label)).tag(RelationshipStatus?.some($0)) }
                        }
                        Button { pickingLanguages = true } label: {
                            HStack {
                                Text("Languages", bundle: bundle).foregroundStyle(.primary)
                                Spacer()
                                Text(viewModel.languages.isEmpty ? bundle.loc("Add")
                                     : viewModel.languages.map { ProfileLanguages.name($0, locale: bundle.locale) }.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        // Plain: a Form tints a button's whole label with the accent colour.
                        .buttonStyle(.plain)
                    } header: {
                        Text("About you", bundle: bundle)
                    }
                    Section(bundle.loc("Education")) {
                        ForEach(schools.schools) { school in
                            Button { editingSchool = SchoolTarget(school: school) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(school.schoolName).foregroundStyle(.primary)
                                    let detail = [school.major, school.yearsText(loc: bundle.loc)].compactMap { $0 }
                                    if !detail.isEmpty {
                                        Text(detail.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Button { editingSchool = SchoolTarget(school: nil) } label: {
                            Label(bundle.loc("Add school"), systemImage: "plus")
                        }
                    }
                }

                // Work only — Hobby never talks about work.
                if appState.currentMode == .work {
                    Section(bundle.loc("Work")) {
                        TextField(bundle.loc("Job title"), text: $viewModel.jobTitle)
                        TextField(bundle.loc("Company"), text: $viewModel.company)
                        SkillPickerView(skills: $viewModel.skills, jobTitle: viewModel.jobTitle, colorScheme: colorScheme)
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
            .sheet(isPresented: $pickingLanguages) { LanguagesPickerView(selected: $viewModel.languages) }
            .sheet(item: $editingSchool) { target in
                EducationEditorView(editing: target.school) { schools.replace($0) }
            }
            .task {
                if appState.currentMode == .hobby, let id = appState.currentUser?.id {
                    await schools.load(userId: id, token: appState.authToken ?? "")
                }
            }
            .navigationTitle(bundle.loc("Edit profile"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConfirmCancelButton { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if viewModel.dobChanged { confirmDobChange = true } else { save() }
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
            .alert(bundle.loc("Change your birthday?"), isPresented: $confirmDobChange) {
                Button(bundle.loc("Change it"), role: .destructive) { save() }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            } message: {
                Text(dobChangeWarning)
            }
        }
    }

    private func save() {
        Task {
            guard let updated = await viewModel.save(mode: appState.currentMode) else { return }
            appState.currentUser = updated
            onSaved?(updated)
            dismiss()
        }
    }

    /// Your age decides what you can use (Dating is 16+), so a birthday can
    /// only change twice; after that, support has to do it.
    @ViewBuilder
    private var dobNote: some View {
        if let left = viewModel.dobChangesLeft {
            Text(left == 0
                 ? String(format: bundle.loc("You've used both birthday changes. To change it again, email %@."),
                          EditProfileViewModel.supportEmail)
                 : String(format: bundle.loc(left == 1 ? "You can change your birthday 1 more time." : "You can change your birthday %lld more times."), left))
                .font(.system(size: 13))
                .foregroundColor(left == 0 ? AppColors.danger(colorScheme) : AppColors.textSecondary(colorScheme))
        }
    }

    private var dobChangeWarning: String {
        let left = max(0, (viewModel.dobChangesLeft ?? 2) - 1)
        let after = left == 0
            ? String(format: bundle.loc("This is your last change — after it, only support (%@) can change your birthday."),
                     EditProfileViewModel.supportEmail)
            : bundle.loc("After this you'll have 1 change left.")
        return bundle.loc("Your age decides what you can use in ConnectSphere, like Dating, so a birthday can only be changed twice.") + " " + after
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

/// A school being added (nil) or edited from Edit profile.
struct SchoolTarget: Identifiable {
    let id = UUID()
    let school: Education?
}
