import SwiftUI

/// Shown after a report goes through: thanks, and two optional steps. Block
/// the author or hide everything from them. Done (or swiping the sheet away)
/// does neither, and the reported post stays where it is.
struct ReportFollowUpSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let authorName: String
    let onBlock: () -> Void
    let onHideAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.green)
                .padding(.top, 32)
            Text("Thanks for letting us know", bundle: bundle)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .padding(.top, 14)
            Text("We use your feedback to help our systems learn when something's not right.", bundle: bundle)
                .font(.system(size: 16))
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 6)

            Text("Other steps you can take", bundle: bundle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 36)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                stepRow(icon: "person.fill.xmark",
                        title: String(format: bundle.loc("Block %@'s profile"), authorName),
                        detail: bundle.loc("You won't be able to see or contact each other.")) {
                    dismiss(); onBlock()
                }
                Divider().padding(.leading, 60)
                stepRow(icon: "eye.slash.fill",
                        title: String(format: bundle.loc("Hide all from %@"), authorName),
                        detail: bundle.loc("Stop seeing posts from this person.")) {
                    dismiss(); onHideAll()
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(AppColors.surface(colorScheme)))
            .padding(.horizontal, 16)

            Spacer(minLength: 16)

            Button { dismiss() } label: {
                Text("Done", bundle: bundle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(themeManager.theme.primary))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(AppColors.base(colorScheme).ignoresSafeArea())
        .presentationDetents([.fraction(0.72), .large])
    }

    private func stepRow(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
