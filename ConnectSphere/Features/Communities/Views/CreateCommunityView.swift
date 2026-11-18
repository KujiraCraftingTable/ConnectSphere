import SwiftUI
import PhotosUI

// Localization keys, resolved through `bundle.loc(...)` at the call site
// (`duplicateWarning`), never rendered directly. These used to be Vietnamese
// literals with no English counterpart at all, so an English-language user
// saw Vietnamese text with no way to fall back.
private let fandomDuplicateWarnings = [
    "Oops, there's already a community with this name! 😄 Try something even cooler~",
    "Name taken! ✨ Your community deserves something more unique!",
    "Uh oh! Someone already snagged this name 🎉 Get a little more creative!",
    "This name's already claimed~ 🌟 You can definitely think of something cooler!",
    "Exact match! 😆 Make your community stand out with its own name!"
]
struct CreateCommunityView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBundle) var bundle

    @State private var viewModel = CreateCommunityViewModel()

    // Real uploaded photo, same pick-now/upload-at-save pattern as EditProfileView.
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showCoverCrop = false
    @State private var showCoverOptions = false

    @State private var warningIndex      = 0
    @State private var wasWarning        = false
    @State private var showValidation    = false

    var existingCommunities: [Community] = []
    let onCreated: (Community) -> Void

    private var isDuplicateName: Bool { viewModel.isDuplicateName(among: existingCommunities) }

    private var duplicateWarning: String {
        let pool = fandomDuplicateWarnings
        return bundle.loc(pool[warningIndex % pool.count])
    }

    private var nameError: String? {
        guard showValidation else { return nil }
        let trimmed = viewModel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty   { return bundle.loc("Please enter a community name") }
        if trimmed.count < 3 { return bundle.loc("Name must be at least 3 characters") }
        if trimmed.count > 100 { return bundle.loc("Name must not exceed 100 characters") }
        return nil
    }

    private var coverError: String? {
        showValidation && viewModel.pickedImage == nil ? bundle.loc("Please add a cover photo") : nil
    }

    var canCreate: Bool { viewModel.canCreate }

    /// Name problems and the duplicate-name joke, under the card.
    @ViewBuilder
    private var nameMessages: some View {
        Group {
            if let err = nameError ?? coverError {
                Text(err)
                    .scaledFont(12)
                    .foregroundColor(.red)
            } else if isDuplicateName {
                Text(duplicateWarning)
                    .scaledFont(13)
                    .foregroundColor(viewModel.type == .fandom ? themeManager.theme.primary : Color.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.2), value: nameError ?? coverError)
        .animation(.easeInOut(duration: 0.2), value: isDuplicateName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Preview chip
                    HStack(spacing: 10) {
                        Button {
                            // A photo picked this session can be re-framed; otherwise choose one.
                            if viewModel.coverOriginal != nil { showCoverOptions = true } else { showPhotoPicker = true }
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                if let pickedImage = viewModel.pickedImage {
                                    Image(uiImage: pickedImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    // No photo yet: a required slot, not a stand-in icon.
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(themeManager.theme.primary.opacity(0.12))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "photo")
                                            .scaledFont(18)
                                            .foregroundColor(themeManager.theme.primary)
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(coverError != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                                    )
                                }
                                ZStack {
                                    Circle().fill(themeManager.theme.primary)
                                        .frame(width: 18, height: 18)
                                    Image(systemName: "camera.fill")
                                        .scaledFont(9)
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Cover photo", bundle: bundle))
                        .axID(AXID.Community.coverButton)
                        .confirmationDialog(bundle.loc("Cover photo"), isPresented: $showCoverOptions) {
                            Button(bundle.loc("Adjust position")) { showCoverCrop = true }
                            Button(bundle.loc("Choose new photo")) { showPhotoPicker = true }
                            Button(bundle.loc("Cancel"), role: .cancel) {}
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            // Edited right on the card: what you type is the name.
                            TextField(bundle.loc("Community name"), text: $viewModel.name)
                                .scaledFont(15, .semibold)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .submitLabel(.done)
                                .onChange(of: viewModel.name) { _, _ in
                                    if showValidation && canCreate { showValidation = false }
                                    refreshWarning()
                                }
                                .onChange(of: viewModel.type) { _, _ in refreshWarning() }
                            Text(bundle.loc(viewModel.type.label))
                                .scaledFont(12)
                                .foregroundColor(themeManager.theme.primary)
                        }
                        Spacer()
                        if viewModel.pickedImage != nil {
                            Button { viewModel.removePhoto() } label: {
                                Image(systemName: "trash")
                                    .scaledFont(15)
                                    .foregroundColor(AppColors.textSecondary(colorScheme))
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove cover photo", bundle: bundle))
                        }
                    }
                    .padding(14)
                    .surfaceBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(nameError != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                    )

                    nameMessages

                    formSection(title: bundle.loc("Description (optional)")) {
                        MarkdownTextEditor(text: $viewModel.description, placeholder: "", size: 15,
                                           minHeight: 80, maxHeight: 80)
                            .padding(8)
                            .background(AppColors.surface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                        Text(String(format: bundle.loc("%lld/%lld words"),
                                    CommunityDescription.wordCount(viewModel.description), CommunityDescription.maxWords))
                            .scaledFont(12)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    // Privacy picker
                    formSection(title: bundle.loc("Privacy")) {
                        HStack(spacing: 0) {
                            privacyTab(.public,  label: bundle.loc("Public"), icon: "globe")
                            privacyTab(.private, label: bundle.loc("Private"),  icon: "lock.fill")
                        }
                        .padding(4)
                        .background(AppColors.surface(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                    }

                    if let err = viewModel.errorMessage {
                        Text(err)
                            .scaledFont(13)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .appBackground()
            .navigationTitle(bundle.loc("Create community"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(viewModel.hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton(hasChanges: viewModel.hasChanges) { dismiss() }
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isCreating {
                        ProgressView().tint(themeManager.theme.primary)
                    } else {
                        Button(bundle.loc("Create")) {
                            guard canCreate else { showValidation = true; return }
                            Task<Void, Never>(name: nil) {
                                guard let community = await viewModel.create(token: appState.authToken) else { return }
                                onCreated(community)
                                dismiss()
                            }
                        }
                        .foregroundColor(canCreate ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if await viewModel.loadPhoto(from: item) { showCoverCrop = true }
                    // Cleared so picking the same photo again still fires.
                    pickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCoverCrop) {
                if let original = viewModel.coverOriginal {
                    CoverCropView(image: original) {
                        viewModel.setFramedCover($0)
                        if showValidation && canCreate { showValidation = false }
                    }
                        .environment(themeManager)
                }
            }
            .onAppear {
                viewModel.type = .fandom
            }
        }
    }

    // MARK: - Helpers

    private func refreshWarning() {
        let isNow = isDuplicateName
        if isNow && !wasWarning {
            warningIndex = Int.random(in: 0..<5)
        }
        wasWarning = isNow
    }

    @ViewBuilder
    private func formSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .scaledFont(13, .semibold)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            content()
        }
    }

    @ViewBuilder
    private func privacyTab(_ p: CommunityPrivacy, label: String, icon: String) -> some View {
        Button { viewModel.privacy = p } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 14, weight: viewModel.privacy == p ? .semibold : .regular))
                .foregroundColor(viewModel.privacy == p ? .white : AppColors.textSecondary(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(viewModel.privacy == p ? themeManager.theme.primary : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

}
