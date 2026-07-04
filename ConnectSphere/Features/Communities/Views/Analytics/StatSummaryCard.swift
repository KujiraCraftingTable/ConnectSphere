import SwiftUI

/// A compact stat card showing a metric and its growth trend
struct StatSummaryCard: View {
    @Environment(\.colorScheme) var colorScheme
    let title:      String
    let value:      String
    let growthRate: Double   // percentage, can be negative
    let icon:       String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(accentColor)
                Spacer()
                growthBadge
            }
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 4, x: 0, y: 2)
    }

    private var growthBadge: some View {
        let isPositive = growthRate >= 0
        let text = String(format: "%@%.1f%%", isPositive ? "+" : "", growthRate)
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isPositive ? .green : .red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isPositive ? Color.green : Color.red).opacity(0.12))
            .clipShape(Capsule())
    }
}
