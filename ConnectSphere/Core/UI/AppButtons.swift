import SwiftUI

/// The primary call to action. Solid palette fill (never a gradient), white
/// label, `AppRadius.md`, 50 pt tall, no shadow. Replaces `GradientButton`,
/// `AppTheme.PrimaryButtonModifier`, and the bespoke onboarding / search /
/// join CTAs.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @Environment(ThemeManager.self) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage).font(AppIcon.sm)
                }
                Text(title).appFont(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(theme.theme.primary.opacity(isEnabled && !isLoading ? 1 : 0.5),
                        in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
        .disabled(!isEnabled || isLoading)
    }
}

/// The lower-emphasis action. Neutral fill, primary text, no palette.
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                if let systemImage { Image(systemName: systemImage).font(AppIcon.sm) }
                Text(title).appFont(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(AppColors.textPrimary(scheme))
            .background(AppColors.elevated(scheme),
                        in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }
}
