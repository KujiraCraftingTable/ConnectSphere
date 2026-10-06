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

    @State private var displayName = ""
    @State private var bio         = ""
    @State private var jobTitle    = ""
    @State private var company     = ""
    @State private var location    = ""
    @State private var email       = ""
    @State private var dob         = ""             // "yyyy-MM-dd", same format OnboardingView uses
    @State private var dobVisibility = "private"
    @State private var selectedInterests: [InterestItem] = []   // picker, same as onboarding
    @State private var skills      = ""                          // comma-separated text, same as onboarding

    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var coverPickerItem: PhotosPickerItem?
    /// The framed cover from `CoverCropView` — exactly what gets uploaded.
    @State private var pickedCover: UIImage?
    /// The photo as picked, kept until Save so the framing can be adjusted again.
    @State private var coverOriginal: UIImage?
    @State private var showCoverPicker = false
    @State private var showCoverCrop = false
    @State private var showCoverOptions = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let profileRepo = ProfileRepository()
    private let postRepo    = PostRepository()   // reuses the image-upload endpoint

    var body: some View {
        NavigationStack {
            Form {
                // ── Cover photo ──────────────────────────────────────────────
                Section(bundle.loc("Cover photo")) {
                    Button {
                        // A photo picked this session can be re-framed; otherwise
                        // go straight to choosing one.
                        if coverOriginal != nil { showCoverOptions = true } else { showCoverPicker = true }
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
                    TextField(bundle.loc("Display name"), text: $displayName)
                    TextField(bundle.loc("About yourself"), text: $bio, axis: .vertical)
                        .lineLimit(3...5)
                    TextField(bundle.loc("Location"), text: $location)
                    TextField(bundle.loc("Email"), text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    DatePicker(bundle.loc("Date of birth"), selection: Binding(
                        get: { dobDate },
                        set: { dob = dobFormatter.string(from: $0) }
                    ), displayedComponents: .date)

                    DobVisibilityToggle(
                        visibility: $dobVisibility,
                        accentColor: themeManager.theme.primary,
                        colorScheme: colorScheme
                    )
                    .padding(.vertical, 4)
                }

                // ── Interests / Skills — based on the current mode, same as onboarding ─
                if appState.currentMode == .hobby {
                    Section(bundle.loc("Interests")) {
                        InterestPickerView(selectedInterests: $selectedInterests, colorScheme: colorScheme)
                            .padding(.vertical, 4)
                    }
                }

                Section(bundle.loc("Work")) {
                    TextField(bundle.loc("Job title"), text: $jobTitle)
                    TextField(bundle.loc("Company"), text: $company)
                    if appState.currentMode == .work {
                        TextField(bundle.loc("Skills (Swift, Python, UI/UX...)"), text: $skills)
                    }
                }

                if let errorMessage {
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
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save", bundle: bundle).fontWeight(.semibold)
                        }
                    }
                    .disabled(isSaving || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        pickedImage = image
                    }
                }
            }
            .photosPicker(isPresented: $showCoverPicker, selection: $coverPickerItem, matching: .images)
            .onChange(of: coverPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        coverOriginal = image
                        showCoverCrop = true
                    }
                    // Cleared so picking the same photo again still fires.
                    coverPickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCoverCrop) {
                if let coverOriginal {
                    CoverCropView(image: coverOriginal) { pickedCover = $0 }
                        .environment(themeManager)
                }
            }
            .confirmationDialog(bundle.loc("Cover photo"), isPresented: $showCoverOptions) {
                Button(bundle.loc("Adjust position")) { showCoverCrop = true }
                Button(bundle.loc("Choose new photo")) { showCoverPicker = true }
                Button(bundle.loc("Cancel"), role: .cancel) {}
            }
            .onAppear { loadCurrentValues() }
        }
    }

    // MARK: - Cover preview

    private var hasCover: Bool {
        pickedCover != nil || !(appState.currentUser?.coverUrl ?? "").isEmpty
    }

    /// Same shape as the profile's cover, so the preview is what the profile shows.
    @ViewBuilder
    private var coverPreview: some View {
        if let pickedCover {
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
        if let pickedImage {
            Image(uiImage: pickedImage)
                .resizable()
                .scaledToFill()
                .frame(width: 90, height: 90)
                .clipShape(Circle())
        } else if let user = appState.currentUser {
            AvatarView(user: user, size: 90)
        }
    }

    // MARK: - Private

    private func loadCurrentValues() {
        guard let user = appState.currentUser else { return }
        displayName = user.name
        bio         = user.bio
        jobTitle    = user.jobTitle ?? ""
        company     = user.company ?? ""
        location    = user.location ?? ""
        email       = user.email ?? ""
        skills      = user.skills.joined(separator: ", ")
        // The dob the backend returns can be either "yyyy-MM-dd" or a full ISO timestamp
        // (Postgres DATE serialized to JSON) — the first 10 characters are always yyyy-MM-dd either way.
        // Accounts predating this feature may not have a dob yet → leave it blank, don't crash.
        dob             = String((user.dob ?? "").prefix(10))
        dobVisibility   = user.dobVisibility ?? "private"
        // Reverse-parse displayText "Anime · Dandadan" → category + rawInput
        selectedInterests = user.interests.map { text in
            let parts = text.components(separatedBy: " · ")
            return InterestItem(
                category: parts[0],
                rawInput: parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : ""
            )
        }
    }

    private var dobDate: Date {
        dobFormatter.date(from: dob) ?? Calendar.current.date(byAdding: .year, value: -20, to: Date())!
    }

    private let dobFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // Upload the new avatar + cover first (if any), get their URLs to PATCH alongside the other fields
        var avatarUrl: String? = nil
        if let pickedImage,
           let data = pickedImage.jpegData(compressionQuality: 0.8) {
            avatarUrl = try? await postRepo.uploadImage(data)
            if avatarUrl == nil {
                errorMessage = bundle.loc("Couldn't upload avatar, please try again")
                return
            }
        }

        var coverUrl: String? = nil
        if let pickedCover,
           let data = pickedCover.jpegData(compressionQuality: 0.85) {
            coverUrl = try? await postRepo.uploadImage(data)
            if coverUrl == nil {
                errorMessage = bundle.loc("Couldn't upload cover photo, please try again")
                return
            }
        }

        // Send both arrays in full (values were pre-loaded, so untouched entries are preserved);
        // the backend replaces user_interests/user_skills wholesale, then re-embeds the profile chunk
        let skillsArray = skills
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let update = ProfileRepository.ProfileUpdate(
            mode:         appState.currentMode.rawValue,  // edits the persona for the current mode
            display_name: displayName.trimmingCharacters(in: .whitespaces),
            bio:          bio.trimmingCharacters(in: .whitespaces),
            location:     location.trimmingCharacters(in: .whitespaces),
            dob:            dob.isEmpty ? nil : dob,
            dob_visibility: dobVisibility,
            job_title:    jobTitle.trimmingCharacters(in: .whitespaces),
            company:      company.trimmingCharacters(in: .whitespaces),
            avatar_url:   avatarUrl,
            cover_url:    coverUrl,
            interests:    selectedInterests.map { $0.displayText },
            skills:       skillsArray,
            email:        email.trimmingCharacters(in: .whitespaces)
        )

        do {
            let updated = try await profileRepo.updateProfile(update)
            appState.currentUser = updated
            onSaved?(updated)
            dismiss()
        } catch {
            errorMessage = bundle.loc("Couldn't save profile, please try again")
        }
    }
}
