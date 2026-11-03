import SwiftUI

// The pieces the interest and skill pickers share: a search field with an
// n/max counter, category sections of chips, and the row of picked chips.
// Buttons are borderless because both pickers also sit inside Form rows,
// where a plain button fires on any tap in the row.

struct CatalogSearchField: View {
    let placeholder: String
    @Binding var text: String
    let count: Int
    let limit: Int
    let colorScheme: ColorScheme
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                TextField(placeholder, text: $text)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Capsule().fill(CatalogChip.idleFill(colorScheme)))
            Text("\(count)/\(limit)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(count >= limit ? themeManager.theme.primary : AppColors.textSecondary(colorScheme))
        }
    }
}

/// An uppercase header over a wrapping row of chips.
struct CatalogSection<Content: View>: View {
    let title: String
    let colorScheme: ColorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .textCase(.uppercase)
                .kerning(0.6)
            FlowLayout(spacing: 8) { content }
        }
    }
}

/// A catalogue entry: filled when picked, faded when the list is full.
struct CatalogChip: View {
    let title: String
    let isSelected: Bool
    var isDimmed = false
    let colorScheme: ColorScheme
    let action: () -> Void
    @Environment(ThemeManager.self) private var themeManager

    static func idleFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isSelected ? .white : AppColors.textPrimary(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(isSelected
                    ? AnyShapeStyle(themeManager.theme.primary)
                    : AnyShapeStyle(Self.idleFill(colorScheme))))
                .opacity(isDimmed && !isSelected ? 0.45 : 1)
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "More" at the end of a collapsed category.
struct CatalogMoreButton: View {
    let action: () -> Void
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle

    var body: some View {
        Button(action: action) {
            Text("More", bundle: bundle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(themeManager.theme.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .buttonStyle(.borderless)
    }
}

/// A picked entry, with ✕ to remove it.
struct CatalogSelectedChip: View {
    let title: String
    let remove: () -> Void
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(String(format: bundle.loc("Remove %@"), title)))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(themeManager.theme.primary))
    }
}
