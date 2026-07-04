import SwiftUI
import PhotosUI

/// Sheet chỉnh sửa hồ sơ — tên, bio, công việc, địa điểm và ảnh đại diện.
/// Lưu qua PATCH /api/users/me rồi cập nhật lại appState.currentUser.
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

    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let profileRepo = ProfileRepository()
    private let postRepo    = PostRepository()   // dùng chung endpoint upload ảnh

    var body: some View {
        NavigationStack {
            Form {
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

                // ── Thông tin cơ bản ─────────────────────────────────────────
                Section(bundle.loc("Thông tin")) {
                    TextField(bundle.loc("Tên hiển thị"), text: $displayName)
                    TextField(bundle.loc("Giới thiệu bản thân"), text: $bio, axis: .vertical)
                        .lineLimit(3...5)
                    TextField(bundle.loc("Địa điểm"), text: $location)
                }

                Section(bundle.loc("Công việc")) {
                    TextField(bundle.loc("Chức danh"), text: $jobTitle)
                    TextField(bundle.loc("Công ty"), text: $company)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(bundle.loc("Chỉnh sửa hồ sơ"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Huỷ")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Lưu", bundle: bundle).fontWeight(.semibold)
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
            .onAppear { loadCurrentValues() }
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
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // Upload avatar mới trước (nếu có), lấy URL để PATCH cùng các field khác
        var avatarUrl: String? = nil
        if let pickedImage,
           let data = pickedImage.jpegData(compressionQuality: 0.8) {
            avatarUrl = try? await postRepo.uploadImage(data)
            if avatarUrl == nil {
                errorMessage = bundle.loc("Không tải được ảnh đại diện, thử lại nhé")
                return
            }
        }

        let update = ProfileRepository.ProfileUpdate(
            display_name: displayName.trimmingCharacters(in: .whitespaces),
            bio:          bio.trimmingCharacters(in: .whitespaces),
            location:     location.trimmingCharacters(in: .whitespaces),
            job_title:    jobTitle.trimmingCharacters(in: .whitespaces),
            company:      company.trimmingCharacters(in: .whitespaces),
            avatar_url:   avatarUrl
        )

        do {
            let updated = try await profileRepo.updateProfile(update)
            appState.currentUser = updated
            onSaved?(updated)
            dismiss()
        } catch {
            errorMessage = bundle.loc("Lưu hồ sơ thất bại, thử lại nhé")
        }
    }
}
