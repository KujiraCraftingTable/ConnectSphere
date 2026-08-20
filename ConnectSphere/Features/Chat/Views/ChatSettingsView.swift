import SwiftUI

/// Settings screen for a single conversation, opened by tapping the header/avatar
/// in `ChatView`. Lets the user set a shared nickname, open the other person's
/// profile, change the shared chat theme, browse media, search, mute, and clear.
struct ChatSettingsView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    @Environment(\.dismiss) private var dismiss

    let conversationId: String
    let otherUserId: String
    let fallbackName: String
    let avatarColor: String
    let token: String
    var onCleared: () -> Void = {}
    /// Chọn một kết quả tìm kiếm — sheet tự đóng rồi báo ChatView nhảy tới tin nhắn
    var onJumpToMessage: (String) -> Void = { _ in }

    @State private var viewModel: ChatSettingsViewModel
    @State private var showNicknameEditor = false
    @State private var nicknameDraft = ""
    @State private var showThemePicker = false
    @State private var showMuteOptions = false
    @State private var showDeleteWarning = false

    init(conversationId: String, otherUserId: String, fallbackName: String,
         avatarColor: String, token: String, onCleared: @escaping () -> Void = {},
         onJumpToMessage: @escaping (String) -> Void = { _ in }) {
        self.conversationId = conversationId
        self.otherUserId = otherUserId
        self.fallbackName = fallbackName
        self.avatarColor = avatarColor
        self.token = token
        self.onCleared = onCleared
        self.onJumpToMessage = onJumpToMessage
        _viewModel = State(initialValue: ChatSettingsViewModel(conversationId: conversationId, token: token))
    }

    private var displayName: String { viewModel.settings?.displayName ?? fallbackName }

    /// Palette currently applied to this conversation (falls back to the global theme).
    private var currentPalette: ThemePalette {
        ThemePalette.byId(viewModel.settings?.theme) ?? themeManager.theme
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    actionsList
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Chat settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { dismiss() }
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .task { await viewModel.load() }
        .alert(bundle.loc("Nickname"), isPresented: $showNicknameEditor) {
            TextField(bundle.loc("Nickname"), text: $nicknameDraft)
            Button(bundle.loc("Save")) { Task { await viewModel.saveNickname(nicknameDraft) } }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("Set a nickname for this person. Both of you will see it.", bundle: bundle)
        }
        .confirmationDialog(bundle.loc("Mute notifications"), isPresented: $showMuteOptions, titleVisibility: .visible) {
            Button(bundle.loc("For 5 minutes"))  { Task { await viewModel.setMute(minutes: 5) } }
            Button(bundle.loc("For 10 minutes")) { Task { await viewModel.setMute(minutes: 10) } }
            Button(bundle.loc("For 30 minutes")) { Task { await viewModel.setMute(minutes: 30) } }
            Button(bundle.loc("Until I turn it back on")) { Task { await viewModel.setMute(minutes: -1) } }
            if viewModel.isMuted {
                Button(bundle.loc("Turn on notifications")) { Task { await viewModel.setMute(minutes: nil) } }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        }
        .alert(bundle.loc("Delete all messages?"), isPresented: $showDeleteWarning) {
            Button(bundle.loc("Delete"), role: .destructive) {
                Task {
                    if await viewModel.clearConversation() {
                        onCleared()
                        dismiss()
                    }
                }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("This removes every message from your side only. The other person will still see them. This can't be undone.", bundle: bundle)
        }
        .sheet(isPresented: $showThemePicker) { themePickerSheet }
    }

    // MARK: - Header (avatar + nickname + profile)

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: avatarColor)).frame(width: 84, height: 84)
                Text(String(displayName.prefix(1)))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 2) {
                Text(displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                // When a nickname is set, show the real name underneath for context.
                if let settings = viewModel.settings, settings.otherUserNickname != nil {
                    Text(settings.otherUserName)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }

            HStack(spacing: 12) {
                Button {
                    nicknameDraft = viewModel.settings?.otherUserNickname ?? ""
                    showNicknameEditor = true
                } label: {
                    pill(icon: "pencil", title: bundle.loc("Nickname"))
                }
                .buttonStyle(.plain)

                NavigationLink {
                    UserProfileView(userId: otherUserId).environment(appState)
                } label: {
                    pill(icon: "person.crop.circle", title: bundle.loc("Profile"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func pill(icon: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(themeManager.theme.primary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppColors.textPrimary(colorScheme))
        }
        .frame(width: 104, height: 62)
        .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions list

    private var actionsList: some View {
        VStack(spacing: 0) {
            Button { showThemePicker = true } label: {
                SettingsRow(icon: "paintpalette.fill", iconColor: currentPalette.primary,
                            title: bundle.loc("Chat theme"), colorScheme: colorScheme,
                            trailing: AnyView(
                                Circle().fill(currentPalette.primaryGradient).frame(width: 22, height: 22)
                            ))
            }
            .buttonStyle(.plain)
            divider

            NavigationLink {
                ChatMediaGalleryView(viewModel: viewModel)
            } label: {
                SettingsRow(icon: "photo.on.rectangle.angled", iconColor: themeManager.theme.primary,
                            title: bundle.loc("Photos & videos"), colorScheme: colorScheme, showsChevron: true)
            }
            .buttonStyle(.plain)
            divider

            NavigationLink {
                ChatMessageSearchView(viewModel: viewModel, onSelect: { message in
                    dismiss()
                    onJumpToMessage(message.id)
                })
            } label: {
                SettingsRow(icon: "magnifyingglass", iconColor: themeManager.theme.primary,
                            title: bundle.loc("Search in conversation"), colorScheme: colorScheme, showsChevron: true)
            }
            .buttonStyle(.plain)
            divider

            Button { showMuteOptions = true } label: {
                SettingsRow(icon: viewModel.isMuted ? "bell.slash.fill" : "bell.fill",
                            iconColor: themeManager.theme.primary,
                            title: bundle.loc("Mute notifications"), colorScheme: colorScheme,
                            subtitle: muteSubtitle)
            }
            .buttonStyle(.plain)
            divider

            Button { showDeleteWarning = true } label: {
                SettingsRow(icon: "trash.fill", iconColor: .red,
                            title: bundle.loc("Delete all messages"), colorScheme: colorScheme,
                            destructive: true)
            }
            .buttonStyle(.plain)
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Divider().padding(.leading, 56)
    }

    /// Subtitle under "Mute notifications" describing the current state.
    private var muteSubtitle: String? {
        guard let settings = viewModel.settings, settings.isMuted, let until = settings.mutedUntil else { return nil }
        if settings.isMutedIndefinitely {
            return bundle.loc("Muted until you turn it back on")
        }
        return String(format: bundle.loc("Muted until %@"), until.formatted(.dateTime.hour().minute()))
    }

    // MARK: - Theme picker

    private var themePickerSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16)], spacing: 16) {
                    ForEach(ThemePalette.allPalettes) { palette in
                        Button {
                            Task { await viewModel.selectTheme(palette.id) }
                            showThemePicker = false
                        } label: {
                            swatch(palette)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Chat theme"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(bundle.loc("Default")) {
                        Task { await viewModel.selectTheme(nil) }
                        showThemePicker = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { showThemePicker = false }
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func swatch(_ palette: ThemePalette) -> some View {
        let isSelected = viewModel.settings?.theme == palette.id
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(palette.primaryGradient).frame(width: 56, height: 56)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .overlay(
                Circle().stroke(AppColors.textPrimary(colorScheme).opacity(isSelected ? 0.9 : 0), lineWidth: 2)
            )
            Text(palette.name)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
    }
}

// MARK: - Reusable settings row

private struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let colorScheme: ColorScheme
    var subtitle: String? = nil
    var destructive: Bool = false
    var showsChevron: Bool = false
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: destructive ? .semibold : .regular))
                    .foregroundColor(destructive ? .red : AppColors.textPrimary(colorScheme))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }

            Spacer()

            if let trailing {
                trailing
            } else if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}
