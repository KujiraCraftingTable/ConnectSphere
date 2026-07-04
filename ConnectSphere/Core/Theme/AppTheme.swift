import SwiftUI

// DEPRECATED: Use AppColors instead for all adaptive light/dark colors.
struct AppTheme {
    static let background    = Color(hex: "#F0F2F5")
    static let card          = Color.white
    static let textPrimary   = Color(hex: "#050505")
    static let textSecondary = Color(hex: "#65676B")
    static let divider       = Color(hex: "#CED0D4")
    static let iconBg        = Color(hex: "#E4E6EB")
}

// MARK: - ViewModifiers

/// Applies primary CTA button styling using the active theme gradient.
struct PrimaryButtonModifier: ViewModifier {
    @Environment(ThemeManager.self) var themeManager

    func body(content: Content) -> some View {
        content
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(themeManager.theme.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: themeManager.theme.primary.opacity(0.4), radius: 12, x: 0, y: 6)
    }
}

/// Applies secondary button styling: themed border + text, transparent fill.
struct SecondaryButtonModifier: ViewModifier {
    @Environment(ThemeManager.self) var themeManager

    func body(content: Content) -> some View {
        content
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(themeManager.theme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(themeManager.theme.primary, lineWidth: 1.5)
            )
    }
}

/// Applies a soft themed card background with border.
struct ThemedCardModifier: ViewModifier {
    @Environment(ThemeManager.self) var themeManager

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(themeManager.theme.softFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(themeManager.theme.softBorder, lineWidth: 1)
                    )
            )
    }
}

/// Applies the theme primary gradient as foreground style (for icons).
struct AccentIconModifier: ViewModifier {
    @Environment(ThemeManager.self) var themeManager

    func body(content: Content) -> some View {
        content.foregroundStyle(themeManager.theme.primaryGradient)
    }
}

/// Applies a soft themed badge: small capsule with theme fill + text color.
struct SoftBadgeModifier: ViewModifier {
    @Environment(ThemeManager.self) var themeManager

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(themeManager.theme.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(themeManager.theme.softFill)
            .clipShape(Capsule())
    }
}

// MARK: - View Extensions

extension View {
    /// Primary CTA button: gradient fill, white text, shadow.
    func primaryButton() -> some View {
        modifier(PrimaryButtonModifier())
    }

    /// Secondary button: themed border + text, transparent fill.
    func secondaryButton() -> some View {
        modifier(SecondaryButtonModifier())
    }

    /// Soft themed card background with border.
    func themedCard() -> some View {
        modifier(ThemedCardModifier())
    }

    /// Gradient tint for active/selected icons.
    func accentIcon() -> some View {
        modifier(AccentIconModifier())
    }

    /// Small capsule badge using theme soft fill and primary text.
    func softBadge() -> some View {
        modifier(SoftBadgeModifier())
    }
}
