import SwiftUI

// MARK: - Palettes
/// Every palette once: Blue is in both the Hobby and Work lists.
private var appIconPalettes: [ThemePalette] {
    var seen = Set<String>()
    return (ThemePalette.socialPalettes + ThemePalette.workPalettes).filter { seen.insert($0.id).inserted }
}

// MARK: - Settings row
/// The Settings row for the app icon: the chosen icon, its name, a chevron. Tapping
/// it opens `AppIconPickerView`, mirroring the Theme color row above it.
struct AppIconRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @State private var showPicker = false

    private var selected: ThemePalette {
        appIconPalettes.first { $0.id == appState.appIconId } ?? .blueShared
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 12) {
                AppIconPreview(palette: selected)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("App icon", bundle: bundle)
                    .scaledFont(16)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Spacer()
                Text(selected.name)
                    .scaledFont(15)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                Image(systemName: "chevron.right")
                    .scaledFont(13)
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
        .sheet(isPresented: $showPicker) {
            AppIconPickerView()
        }
    }
}

// MARK: - Picker
/// The sheet: the whale icon in each theme colour, four to a row.
struct AppIconPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: AppSpacing.md), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: AppSpacing.lg) {
                    ForEach(appIconPalettes) { palette in
                        tile(palette)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(bundle.loc("App icon"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(bundle.loc("Done")) { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(themeManager.theme.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.selection, trigger: appState.appIconId)
    }

    private func tile(_ palette: ThemePalette) -> some View {
        let isSelected = appState.appIconId == palette.id
        return Button {
            appState.selectAppIcon(palette.id)
        } label: {
            VStack(spacing: 6) {
                AppIconPreview(palette: palette)
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(isSelected ? themeManager.theme.primary : AppColors.borderDefault(colorScheme),
                                    lineWidth: isSelected ? 2.5 : 1)
                    )
                Text(palette.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(palette.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Icon previews
/// The real icon, from the `AppIconPreview-<id>` imageset that `scripts/app-icon/make.py`
/// exports next to each icon set (alternate icon sets can't be loaded as images at runtime).
struct AppIconPreview: View {
    let palette: ThemePalette

    var body: some View {
        Image("AppIconPreview-\(palette.id)")
            .resizable()
            .scaledToFit()
    }
}

/// The app icon you picked, at `size`, with the home-screen corner shape: the
/// splash and sign-in screens show it so they match the icon you tapped.
struct CurrentAppIcon: View {
    @Environment(AppState.self) private var appState
    let size: CGFloat

    var body: some View {
        Image("AppIconPreview-\(appState.appIconId)")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}
