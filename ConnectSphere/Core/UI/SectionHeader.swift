import SwiftUI

/// A list/section heading: title, an optional count, an optional trailing
/// action. Replaces the per-screen `typeSectionHeader` / posts-header /
/// skills-header re-implementations.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 2) {
            Text(title)
                .appFont(.title3)
                .foregroundStyle(AppColors.textPrimary(scheme))
            if let count {
                Text("\(count)")
                    .appFont(.subheadline)
                    .foregroundStyle(AppColors.textTertiary(scheme))
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, AppSpacing.xs)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title: title, count: count, trailing: { EmptyView() })
    }
}
