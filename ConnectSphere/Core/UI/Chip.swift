import SwiftUI

/// Small pill label. The default `.neutral` style (secondary text on an
/// elevated fill) is what interests / skills / hashtags use at rest — the
/// single biggest lever for making 12 loud palettes read calm. Palette color
/// is reserved for `.accent` (an interactive filter) and the on-state of
/// `.selectable`.
struct Chip: View {
    enum Style: Equatable {
        case neutral
        case accent
        case selectable(isSelected: Bool)
    }

    let text: String
    var style: Style = .neutral

    @Environment(\.colorScheme) private var scheme
    @Environment(ThemeManager.self) private var theme

    var body: some View {
        Text(text)
            .appFont(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 1)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(Capsule())
            .overlay {
                if case .selectable(false) = style {
                    Capsule().strokeBorder(AppColors.borderSubtle(scheme), lineWidth: 1)
                }
            }
    }

    private var foreground: Color {
        switch style {
        case .neutral:                 return AppColors.textSecondary(scheme)
        case .accent:                  return theme.theme.primary
        case .selectable(let on):      return on ? .white : AppColors.textSecondary(scheme)
        }
    }

    private var background: Color {
        switch style {
        case .neutral:                 return AppColors.elevated(scheme)
        case .accent:                  return theme.theme.primary.opacity(0.12)
        case .selectable(let on):      return on ? theme.theme.primary : AppColors.elevated(scheme)
        }
    }
}
