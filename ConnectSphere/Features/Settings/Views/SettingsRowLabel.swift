import SwiftUI

/// A settings row: a coloured 30×30 tile with a white icon, then the label.
struct SettingsRowLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let label: String
    let color: Color
    /// A NavigationLink inside a List draws its own chevron; buttons pass true.
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color)
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            Text(label)
                .font(.system(size: 16))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
        }
    }
}
