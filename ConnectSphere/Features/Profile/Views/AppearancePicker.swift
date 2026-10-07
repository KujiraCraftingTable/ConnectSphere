import SwiftUI

/// Settings › Appearance: three tiles (System / Light / Dark), each a tiny
/// preview of the app in that look, à la iOS Display & Brightness. Lives in a
/// normal card row so it matches every other Settings section.
struct AppearancePicker: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                tile(mode)
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tile(_ mode: AppearanceMode) -> some View {
        let isSelected = selection == mode
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = mode }
        } label: {
            VStack(spacing: AppSpacing.sm) {
                AppearancePreview(mode: mode)
                    .frame(width: 58, height: 92)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? themeManager.theme.primary : AppColors.borderDefault(colorScheme),
                                          lineWidth: isSelected ? 2 : 1)
                    )
                Text(bundle.loc(mode.label))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bundle.loc(mode.label)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature phone screen in one look: page colour, a header bar and two
/// cards. System shows light and dark split diagonally.
private struct AppearancePreview: View {
    let mode: AppearanceMode

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            switch mode {
            case .light:  screen(.light)
            case .dark:   screen(.dark)
            case .system:
                screen(.light)
                    .overlay { screen(.dark).mask(DiagonalHalf()) }
            }
        }
        .clipShape(shape)
    }

    private func screen(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(AppColors.textPrimary(scheme).opacity(0.75)).frame(width: 22, height: 4)
                .padding(.bottom, 2)
            card(scheme, height: 26)
            card(scheme, height: 18)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.base(scheme))
    }

    private func card(_ scheme: ColorScheme, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(AppColors.surface(scheme))
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                Capsule().fill(AppColors.textSecondary(scheme).opacity(0.5))
                    .frame(width: 18, height: 3)
                    .padding(4)
            }
    }
}

/// Bottom-right triangle of the rect.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
