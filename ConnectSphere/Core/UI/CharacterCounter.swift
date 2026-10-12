import SwiftUI

/// "12/30" beside a text field with a length limit; turns the accent colour
/// once the limit is reached, so it's clear why typing stopped.
struct CharacterCounter: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let count: Int
    let limit: Int

    var body: some View {
        Text("\(count)/\(limit)")
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(count >= limit ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
            .accessibilityLabel(Text(String(format: bundle.loc("%lld of %lld characters"), count, limit)))
    }
}
