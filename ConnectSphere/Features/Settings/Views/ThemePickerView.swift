// ThemePickerView — lets the user select a palette per app mode.
// Shows two sections (Friend / Colleague), a horizontal chip scroll,
// and a live preview card that updates instantly on selection.

import SwiftUI

struct ThemePickerView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) var appState
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    /// The signed-in person, so the preview shows their own name and tags
    /// (sample data only if there's somehow no profile loaded).
    private var previewUser: UserProfile { appState.currentUser ?? MockData.currentUser }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    livePreviewCard
                        .padding(.top, 8)

                    paletteSection(
                        title: bundle.loc("Hobby Mode"),
                        icon: AppMode.hobby.glyph,
                        palettes: ThemePalette.socialPalettes,
                        activeId: themeManager.socialPaletteId,
                        targetMode: .hobby
                    )

                    paletteSection(
                        title: bundle.loc("Work Mode"),
                        icon: AppMode.work.glyph,
                        palettes: ThemePalette.workPalettes,
                        activeId: themeManager.workPaletteId,
                        targetMode: .work
                    )

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(bundle.loc("Customize appearance"))
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                // The preview may have switched themeManager to a mode whose switch is blocked
                // (persona not set up yet) → leaving this screen re-syncs it to the app's real mode
                themeManager.switchMode(appState.currentMode)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
    }

    // MARK: Live Preview Card

    private var livePreviewCard: some View {
        VStack(spacing: 0) {
            // Header label
            HStack {
                Text("Preview", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                Spacer()
                // Active mode badge
                HStack(spacing: 4) {
                    Image(systemName: themeManager.currentMode.glyph)
                        .font(.system(size: 10))
                    Text(themeManager.currentMode == .hobby ? bundle.loc("Hobby Mode") : bundle.loc("Work Mode"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(themeManager.theme.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(themeManager.theme.softFill)
                .clipShape(Capsule())
            }
            .padding(.bottom, 10)

            // Card
            HStack(spacing: 14) {
                // Avatar ring
                ZStack {
                    // Flat, like everywhere the theme colour is used in the app —
                    // the preview shouldn't promise a gradient or glow it won't show.
                    Circle()
                        .fill(themeManager.theme.primary)
                        .frame(width: 54, height: 54)
                    Text(String(previewUser.name.prefix(1)))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(previewUser.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Circle()
                            .fill(themeManager.theme.accent)
                            .frame(width: 8, height: 8)
                    }

                    // Tags
                    let tags = themeManager.currentMode == .hobby
                        ? previewUser.interests.prefix(3)
                        : previewUser.skills.prefix(3)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(tags), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(themeManager.theme.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(themeManager.theme.softFill)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                Spacer()

                // Connect button
                Text("Connect", bundle: bundle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(themeManager.theme.primary)
                    .clipShape(Capsule())
            }
            .padding(16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
            )
        }
    }

    // MARK: Palette Section

    private func paletteSection(
        title: String,
        icon: String,
        palettes: [ThemePalette],
        activeId: String,
        targetMode: AppMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(targetMode == themeManager.currentMode
                                     ? themeManager.theme.primary
                                     : .secondary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                if targetMode == themeManager.currentMode {
                    Text("Active", bundle: bundle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(themeManager.theme.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(themeManager.theme.softFill)
                        .clipShape(Capsule())
                }
            }

            // Chip scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(palettes) { palette in
                        paletteChip(
                            palette: palette,
                            isSelected: activeId == palette.id,
                            targetMode: targetMode
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Palette Chip

    private func paletteChip(
        palette: ThemePalette,
        isSelected: Bool,
        targetMode: AppMode
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                // Switch to this mode so preview updates immediately.
                // If the mode's persona isn't set up yet, requestModeSwitch blocks the switch and shows
                // the persona-creation form instead; that mode's theme is still saved normally.
                appState.requestModeSwitch(to: targetMode)
                themeManager.switchMode(targetMode)
                themeManager.selectPalette(id: palette.id)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    // Selection ring
                    if isSelected {
                        Circle()
                            .stroke(palette.primary, lineWidth: 2.5)
                            .frame(width: 50, height: 50)
                    }
                    // The colour exactly as the app uses it (flat, no gradient).
                    Circle()
                        .fill(palette.primary)
                        .frame(width: isSelected ? 40 : 44, height: isSelected ? 40 : 44)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 50, height: 50)

                Text(palette.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? palette.primary : AppColors.textSecondary(colorScheme))
                    .lineLimit(1)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    ThemePickerView()
        .environment(ThemeManager())
        .environment(AppState())
}
