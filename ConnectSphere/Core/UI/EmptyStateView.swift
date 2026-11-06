import SwiftUI

/// The one "nothing here" / "that failed" visual. Icon or emoji, a title, an
/// optional message, an optional action button. `mascot: true` uses the 🐳
/// Kujira layout so Search's empty/retry states share it. `ContentStateView`
/// routes both its empty and failed branches here.
struct EmptyStateView: View {
    var systemImage: String? = nil
    var emoji: String? = nil
    var mascot: Bool = false
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            if mascot {
                Text("🐳").scaledFont(44)
            } else if let emoji {
                Text(emoji).scaledFont(40)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .scaledFont(38)
                    .foregroundStyle(AppColors.textTertiary(scheme))
            }

            VStack(spacing: AppSpacing.xs) {
                Text(title)
                    .appFont(.headline)
                    .foregroundStyle(AppColors.textSecondary(scheme))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .appFont(.footnote)
                        .foregroundStyle(AppColors.textTertiary(scheme))
                        .multilineTextAlignment(.center)
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .appFont(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.top, AppSpacing.xs)
            }
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, AppSpacing.xxl)
        .frame(maxWidth: .infinity)
    }
}
