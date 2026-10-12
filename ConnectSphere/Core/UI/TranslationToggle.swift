import SwiftUI

/// The line under a translatable post or comment: "Show translation", or
/// once swapped, "Translated by AI · Show original".
struct TranslationToggle: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let showingTranslation: Bool
    var fontSize: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if showingTranslation {
                    Image(systemName: "sparkles")
                    Text("Translated by AI", bundle: bundle)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                    Text(verbatim: "·").foregroundColor(AppColors.textTertiary(colorScheme))
                    Text("Show original", bundle: bundle)
                        .foregroundColor(themeManager.theme.primary)
                } else {
                    Image(systemName: "character.bubble")
                    Text("Show translation", bundle: bundle)
                        .foregroundColor(themeManager.theme.primary)
                }
            }
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(AppColors.textTertiary(colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
