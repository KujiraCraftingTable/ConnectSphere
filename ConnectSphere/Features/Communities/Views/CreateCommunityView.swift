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

    @State private var viewModel = CreateCommunityViewModel(defaultEmoji: fandomEmojis[0])

    // Real uploaded photo, same pick-now/upload-at-save pattern as EditProfileView.
    @State private var pickerItem: PhotosPickerItem?

    @State private var customEmoji: String?  = nil
    @State private var showCustomEmojiInput  = false
    @State private var customEmojiDraft      = ""
    @FocusState private var emojiInputFocused: Bool

    @State private var warningIndex      = 0
    @State private var wasWarning        = false
    @State private var showValidation    = false

    var existingCommunities: [Community] = []
    let onCreated: (Community) -> Void

    private var isDuplicateName: Bool { viewModel.isDuplicateName(among: existingCommunities) }

    private var duplicateWarning: String {
        let pool = viewModel.type == .work ? workDuplicateWarnings : fandomDuplicateWarnings
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

    var canCreate: Bool { viewModel.canCreate }

    private var currentEmojiSet: [String] { viewModel.type == .work ? workEmojis : fandomEmojis }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Preview chip
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                if let pickedImage = viewModel.pickedImage {
                                    Image(uiImage: pickedImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(hex: viewModel.selectedColor).opacity(0.18))
                                            .frame(width: 44, height: 44)
                                        Text(viewModel.selectedEmoji).font(.system(size: 22))
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
                            Text(viewModel.name.isEmpty ? bundle.loc("Community name") : viewModel.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(viewModel.name.isEmpty
                                    ? AppColors.textTertiary(colorScheme)
                                    : AppColors.textPrimary(colorScheme))
                            Text(bundle.loc(viewModel.type.label))
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: viewModel.selectedColor))
                        }
                        Spacer()
                    }
                    .padding(14)
                    .surfaceBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    formSection(title: bundle.loc("Name")) {
                        TextField(bundle.loc("3–100 characters"), text: $viewModel.name)
                            .font(.system(size: 15))
                            .padding(12)
                            .background(AppColors.surface(colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(nameError != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                            .onChange(of: viewModel.name) { _, _ in
                                if showValidation && canCreate { showValidation = false }
                                refreshWarning()
                            }
                            .onChange(of: viewModel.type) { _, _ in refreshWarning() }

                        if let err = nameError {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .padding(.horizontal, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else if isDuplicateName {
                            Text(duplicateWarning)
                                .font(.system(size: 13))
                                .foregroundColor(viewModel.type == .fandom
                                    ? themeManager.theme.primary
                                    : Color.red)
                                .padding(.horizontal, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: nameError != nil)
                    .animation(.easeInOut(duration: 0.2), value: isDuplicateName)

                    formSection(title: bundle.loc("Description (optional)")) {
                        TextEditor(text: $viewModel.description)
                            .font(.system(size: 15))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(AppColors.surface(colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                            .frame(height: 80)
                        Text(String(format: bundle.loc("%lld/%lld words"),
                                    CommunityDescription.wordCount(viewModel.description), CommunityDescription.maxWords))
                            .font(.system(size: 12))
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
                                        viewModel.selectedEmoji        = picked
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
                                    viewModel.selectedColor = hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle().stroke(.white, lineWidth: viewModel.selectedColor == hex ? 3 : 0)
                                        )
                                        .shadow(color: Color(hex: hex).opacity(0.5), radius: 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ColorPicker(selection: Binding(
                            get: { Color(hex: viewModel.selectedColor) },
                            set: { viewModel.selectedColor = $0.toHex() ?? viewModel.selectedColor }
                        ), supportsOpacity: false) {
                            Text("Custom color", bundle: bundle)
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                        .padding(.top, 4)
                    }

                    if let err = viewModel.errorMessage {
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
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ConfirmCancelButton { dismiss() }
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
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await viewModel.loadPhoto(from: item) }
            }
            .onAppear {
                viewModel.type = appState.currentMode == .hobby ? .fandom : .work
            }
            .onChange(of: viewModel.type) { _, newType in
                // Reset to first emoji of new type if current selection doesn't belong
                let set = newType == .work ? workEmojis : fandomEmojis
                if !set.contains(viewModel.selectedEmoji) && customEmoji != viewModel.selectedEmoji {
                    viewModel.selectedEmoji = set[0]
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
        Button { viewModel.selectedEmoji = emoji } label: {
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 34, height: 34)
                .background(viewModel.selectedEmoji == emoji
                    ? Color(hex: viewModel.selectedColor).opacity(0.18)
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
