// AppMetrics, the non-color half of the design system: type scale, spacing,
// radius, elevation, icon sizes. Pairs with AppColors (color) and ThemeManager
// (per-mode palette). See plan: content-first, Apple-native, Dynamic Type
// supported but capped at the view roots.

import SwiftUI

// MARK: - Type scale

/// Named text styles. Each carries a base point size + weight and scales with
/// Dynamic Type relative to a system text style (via `@ScaledMetric` inside
/// `AppFontModifier`), so a size change is live, not launch-time.
///
/// Use `.appFont(_:)` on a view, `Text("Hi").appFont(.headline)`, the same
/// shape as the `.font(...)` it replaces. Glyph sizing stays on `AppIcon`.
enum AppFont {
    case largeTitle, title, title2, title3
    case headline, body, callout, subheadline
    case footnote, caption, caption2

    var spec: (size: CGFloat, weight: Font.Weight, relativeTo: Font.TextStyle) {
        switch self {
        case .largeTitle:  return (28, .bold,     .largeTitle)
        case .title:       return (22, .semibold, .title)
        case .title2:      return (20, .semibold, .title2)
        case .title3:      return (17, .semibold, .title3)
        case .headline:    return (15, .semibold, .headline)
        case .body:        return (15, .regular,  .body)
        case .callout:     return (14, .regular,  .callout)
        case .subheadline: return (13, .medium,   .subheadline)
        case .footnote:    return (12, .regular,  .footnote)
        case .caption:     return (11, .regular,  .caption)
        case .caption2:    return (10, .regular,  .caption2)
        }
    }
}

private struct AppFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(_ style: AppFont) {
        let s = style.spec
        _size = ScaledMetric(wrappedValue: s.size, relativeTo: s.relativeTo)
        weight = s.weight
    }
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    /// Apply a design-system text style (Dynamic Type-aware). Replaces
    /// `.font(.system(size:weight:))`.
    func appFont(_ style: AppFont) -> some View { modifier(AppFontModifier(style)) }

    /// Cap Dynamic Type so dense feed/chat layouts with fixed-height controls
    /// don't clip. Apply once at a screen/app root.
    func cappedDynamicType() -> some View { dynamicTypeSize(...DynamicTypeSize.xLarge) }
}

// MARK: - Icon glyph sizes (not Dynamic Type. Deliberate)

enum AppIcon {
    static let xs: Font = .system(size: 11)
    static let sm: Font = .system(size: 13)
    static let md: Font = .system(size: 17)
    static let lg: Font = .system(size: 22)
    static let xl: Font = .system(size: 28)
}

// MARK: - Spacing (4 / 8 pt rhythm)

enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner radius

enum AppRadius {
    static let sm: CGFloat = 8    // chips, inner media
    static let md: CGFloat = 12   // cards, buttons
    static let lg: CGFloat = 16   // sheets, grouped panels
    static let pill: CGFloat = 999
}

// MARK: - Elevation (two levels only. Chrome recedes; hairlines elsewhere)

enum AppElevation {
    /// Resting card / row surface lift.
    case card
    /// Sheets, popovers, toasts.
    case overlay

    var radius: CGFloat { self == .card ? 3 : 16 }
    var y:      CGFloat { self == .card ? 1 : 4 }
    func color(_ scheme: ColorScheme) -> Color {
        let a: Double = self == .card
            ? (scheme == .dark ? 0.22 : 0.05)
            : (scheme == .dark ? 0.40 : 0.14)
        return .black.opacity(a)
    }
}

// MARK: - Card style

private struct CardStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(AppColors.surface(scheme))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .shadow(color: AppElevation.card.color(scheme),
                    radius: AppElevation.card.radius, x: 0, y: AppElevation.card.y)
    }
}

extension View {
    /// Canonical card container: surface fill + `AppRadius.md` + the single
    /// resting shadow. Replaces the copy-pasted inline shadow blocks.
    func cardStyle() -> some View { modifier(CardStyleModifier()) }
}
