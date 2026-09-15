import SwiftUI
import PhotosUI

private let fandomEmojis = ["🎵","🎮","📚","🍕","✈️","🎨","🏆","🐾","🎬","🎤",
                             "🌸","🦊","⚽","🏀","🎯","🎲","🧩","🌙","🎭","🎪"]
private let workEmojis   = ["💼","💻","🔬","🌎","📊","📈","🏢","🤝","📋","✉️",
                             "🔧","⚙️","📱","💡","🎓","🏅","📌","🗂️","🖥️","📝"]

// Localization keys — resolved through `bundle.loc(...)` at the call site
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
private let workDuplicateWarnings = [
    "This community name already exists. Please choose a different name to continue.",
    "A community with this name already exists in the system. Please use a distinct identifier.",
    "This name matches an existing community. Please adjust it to ensure uniqueness.",
    "A community with this name has already been created. Please choose another name.",
    "Invalid name: already exists in the system. Please enter a different name."
]
private let colorPreset  = [
    "#7F5AF0","#F72585","#2196F3","#00BCD4","#4CAF50",
    "#FF9800","#E91E63","#607D8B","#795548","#9C27B0",
    "#F44336","#FF5722","#FFEB3B","#8BC34A","#009688",
    "#3F51B5","#00ACC1","#AB47BC","#EC407A","#546E7A"
]

struct CreateCommunityView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.appBundle) var bundle

    @State private var name        = ""
    @State private var description = ""
    @State private var type: CommunityType       = .fandom
    @State private var privacy: CommunityPrivacy = .public
    @State private var selectedEmoji = fandomEmojis[0]
    @State private var selectedColor = "#7F5AF0"
    @State private var isCreating    = false
    @State private var errorMessage: String?

    // Real uploaded photo, same pick-now/upload-at-save pattern as EditProfileView.
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    private let postRepo = PostRepository()

    @State private var customEmoji: String?  = nil
    @State private var showCustomEmojiInput  = false
    @State private var customEmojiDraft      = ""
    @FocusState private var emojiInputFocused: Bool

    @State private var warningIndex      = 0
    @State private var wasWarning        = false
    @State private var showValidation    = false

    var existingCommunities: [Community] = []
    let onCreated: (Community) -> Void

    private var isDuplicateName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 3 else { return false }
        return existingCommunities.contains { $0.name.lowercased() == trimmed && $0.type == type }
    }

    private var duplicateWarning: String {
        let pool = type == .work ? workDuplicateWarnings : fandomDuplicateWarnings
        return bundle.loc(pool[warningIndex % pool.count])
    }

    private var nameError: String? {
        guard showValidation else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty   { return bundle.loc("Please enter a community name") }
        if trimmed.count < 3 { return bundle.loc("Name must be at least 3 characters") }
        if trimmed.count > 100 { return bundle.loc("Name must not exceed 100 characters") }
        return nil
    }

    var canCreate: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }

    private var currentEmojiSet: [String] { type == .work ? workEmojis : fandomEmojis }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Preview chip
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                if let pickedImage {
                                    Image(uiImage: pickedImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(Circle())
                                } else {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(hex: selectedColor).opacity(0.18))
                                            .frame(width: 44, height: 44)
                                        Text(selectedEmoji).font(.system(size: 22))
                                    }
                                }
                                ZStack {
                                    Circle().fill(themeManager.theme.primary)
                                        .frame(width: 18, height: 18)
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name.isEmpty ? bundle.loc("Community name") : name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(name.isEmpty
                                    ? AppColors.textTertiary(colorScheme)
                                    : AppColors.textPrimary(colorScheme))
                            Text(bundle.loc(type.label))
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: selectedColor))
                        }
                        Spacer()
                    }
                    .padding(14)
                    .surfaceBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    formSection(title: bundle.loc("Name")) {
                        TextField(bundle.loc("3–100 characters"), text: $name)
                            .font(.system(size: 15))
                            .padding(12)
                            .background(AppColors.surface(colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(nameError != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                            .onChange(of: name) { _, _ in
                                if showValidation && canCreate { showValidation = false }
                                refreshWarning()
                            }
                            .onChange(of: type) { _, _ in refreshWarning() }

                        if let err = nameError {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .padding(.horizontal, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if isDuplicateName {
                            Text(duplicateWarning)
                                .font(.system(size: 13))
                                .foregroundColor(type == .fandom
                                    ? themeManager.theme.primary
                                    : Color.red)
                                .padding(.horizontal, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: nameError != nil)
                    .animation(.easeInOut(duration: 0.2), value: isDuplicateName)

                    formSection(title: bundle.loc("Description (optional)")) {
                        TextEditor(text: $description)
                            .font(.system(size: 15))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(AppColors.surface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                            .frame(height: 80)
                            .onChange(of: description) { _, new in
                                if new.count > 500 { description = String(new.prefix(500)) }
                            }
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

                    // Emoji picker
                    formSection(title: bundle.loc("Icon")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 10), spacing: 8) {
                            ForEach(currentEmojiSet, id: \.self) { emoji in
                                emojiCell(emoji)
                            }
                            // Custom emoji cell (if added by user)
                            if let custom = customEmoji, !currentEmojiSet.contains(custom) {
                                emojiCell(custom)
                            }
                        }

                        // "+" row — left-aligned, mirrors "Custom color" below
                        if showCustomEmojiInput {
                            HStack(spacing: 10) {
                                TextField(bundle.loc("Type or paste an emoji…"), text: $customEmojiDraft)
                                    .focused($emojiInputFocused)
                                    .font(.system(size: 22))
                                    .multilineTextAlignment(.center)
                                    .frame(width: 50, height: 44)
                                    .background(AppColors.surface(colorScheme))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                                    .onChange(of: customEmojiDraft) { _, new in
                                        guard !new.isEmpty else { return }
                                        let picked = String(new.prefix(1))
                                        customEmoji          = picked
                                        selectedEmoji        = picked
                                        showCustomEmojiInput = false
                                        customEmojiDraft     = ""
                                    }
                                Text("Type or paste any emoji", bundle: bundle)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textTertiary(colorScheme))
                                Spacer()
                                Button(bundle.loc("Cancel")) {
                                    showCustomEmojiInput = false
                                    customEmojiDraft     = ""
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            .padding(.top, 4)
                        } else {
                            Button {
                                showCustomEmojiInput = true
                                emojiInputFocused    = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle")
                                    Text("Add emoji", bundle: bundle)
                                }
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }

                    // Color picker
                    formSection(title: bundle.loc("Cover color")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 10), spacing: 10) {
                            ForEach(colorPreset, id: \.self) { hex in
                                Button {
                                    selectedColor = hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle().stroke(.white, lineWidth: selectedColor == hex ? 3 : 0)
                                        )
                                        .shadow(color: Color(hex: hex).opacity(0.5), radius: 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ColorPicker(selection: Binding(
                            get: { Color(hex: selectedColor) },
                            set: { selectedColor = $0.toHex() ?? selectedColor }
                        ), supportsOpacity: false) {
                            Text("Custom color", bundle: bundle)
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                        .padding(.top, 4)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .appBackground()
            .navigationTitle(bundle.loc("Create community"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc("Cancel")) { dismiss() }
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView().tint(themeManager.theme.primary)
                    } else {
                        Button(bundle.loc("Create")) {
                            guard canCreate else { showValidation = true; return }
                            Task<Void, Never>(name: nil) { await create() }
                        }
                        .foregroundColor(canCreate ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                    }
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
            .onAppear {
                type = appState.currentMode == .hobby ? .fandom : .work
            }
            .onChange(of: type) { _, newType in
                // Reset to first emoji of new type if current selection doesn't belong
                let set = newType == .work ? workEmojis : fandomEmojis
                if !set.contains(selectedEmoji) && customEmoji != selectedEmoji {
                    selectedEmoji = set[0]
                }
                customEmoji         = nil
                showCustomEmojiInput = false
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
    private func emojiCell(_ emoji: String) -> some View {
        Button { selectedEmoji = emoji } label: {
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 34, height: 34)
                .background(selectedEmoji == emoji
                    ? Color(hex: selectedColor).opacity(0.18)
                    : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func formSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            content()
        }
    }

    @ViewBuilder
    private func privacyTab(_ p: CommunityPrivacy, label: String, icon: String) -> some View {
        Button { privacy = p } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 14, weight: privacy == p ? .semibold : .regular))
                .foregroundColor(privacy == p ? .white : AppColors.textSecondary(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(privacy == p ? themeManager.theme.primary : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func create() async {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil

        // Upload the picked photo first (if any) — same pick-now/upload-at-save
        // ordering EditProfileView uses, so nothing's uploaded until Create is
        // actually confirmed.
        var avatarUrl: String? = nil
        if let pickedImage, let data = pickedImage.jpegData(compressionQuality: 0.8) {
            avatarUrl = try? await postRepo.uploadImage(data)
            if avatarUrl == nil {
                errorMessage = bundle.loc("Couldn't upload photo, please try again")
                isCreating = false
                return
            }
        }

        let descTrimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let community = try await CommunityRepository().createCommunity(
                name:        name.trimmingCharacters(in: .whitespacesAndNewlines),
                type:        type.rawValue,
                privacy:     privacy.rawValue,
                iconEmoji:   selectedEmoji,
                coverColor:  selectedColor,
                avatarUrl:   avatarUrl,
                description: descTrimmed.isEmpty ? nil : descTrimmed,
                token:       appState.authToken ?? ""
            )
            onCreated(community)
            dismiss()
        } catch {
            if case APIError.serverError(_, let msg) = error { errorMessage = msg }
            else { errorMessage = bundle.loc("Could not create community. Please try again.") }
        }
        isCreating = false
    }
}
