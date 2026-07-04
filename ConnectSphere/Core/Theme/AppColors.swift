// AppColors — adaptive color token system for Light (Warm White) and Dark (Soft Dark) modes.
// Replaces AppTheme static colors in all Feature views.
// Auth views always use .light tokens directly (force light mode).

import SwiftUI

// MARK: - Token functions

struct AppColors {

    // MARK: Background elevation

    static func base(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#0D0D12") : Color(hex: "#F2F1EE")
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#181820") : Color(hex: "#FFFFFF")
    }
    static func elevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#202029") : Color(hex: "#F5F3EF")
    }
    static func modal(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#2C2C37") : Color(hex: "#ECEAE5")
    }

    // MARK: Text

    static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(hex: "#1A1916")
    }
    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.55) : Color(hex: "#6B6960")
    }
    static func textTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.30) : Color(hex: "#9E9B94")
    }
    static func textDisabled(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.20) : Color(hex: "#C4C1BA")
    }

    // MARK: Border / Divider

    static func borderSubtle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
    static func borderDefault(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
    }
    static func borderStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.15)
    }

    // MARK: State overlays

    static func stateHover(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }
    static func statePressed(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
    }
    static func stateSelected(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.09)
    }
}

// MARK: - ViewModifiers

private struct AppBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    func body(content: Content) -> some View {
        content.background(AppColors.base(colorScheme).ignoresSafeArea())
    }
}

private struct SurfaceBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    func body(content: Content) -> some View {
        content.background(AppColors.surface(colorScheme))
    }
}

private struct ElevatedBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    func body(content: Content) -> some View {
        content.background(AppColors.elevated(colorScheme))
    }
}

// MARK: - View extensions

extension View {
    /// Fills the view with the page/scroll background, ignoring safe area.
    func appBackground() -> some View { modifier(AppBackgroundModifier()) }
    /// Fills the view with the card/list-row surface color.
    func surfaceBackground() -> some View { modifier(SurfaceBackgroundModifier()) }
    /// Fills the view with the nested-card/section elevated color.
    func elevatedBackground() -> some View { modifier(ElevatedBackgroundModifier()) }
}
