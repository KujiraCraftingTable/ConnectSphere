import SwiftUI

// Grey stand-ins shaped like the rows about to load, shown on a screen's
// first load instead of a lone spinner: the layout appears at once and the
// content fills in where the eye already is. Later refreshes keep the content.

/// A soft highlight sweeping across, so a skeleton reads as "loading".
struct Shimmer: ViewModifier {
    @Environment(\.appBundle) private var bundle
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Loading...", bundle: bundle))
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

private struct Bone: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    let colorScheme: ColorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(AppColors.elevated(colorScheme))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A post card: author line, three lines of text, a photo block.
struct SkeletonPostCard: View {
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(AppColors.elevated(colorScheme)).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Bone(width: 130, height: 12, colorScheme: colorScheme)
                    Bone(width: 70, height: 10, colorScheme: colorScheme)
                }
            }
            Bone(colorScheme: colorScheme)
            Bone(colorScheme: colorScheme)
            Bone(width: 180, colorScheme: colorScheme)
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.elevated(colorScheme))
                .frame(height: 180)
        }
        .padding(16)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 18))
        .shimmering()
    }
}

/// A person or notification row: avatar and two lines.
struct SkeletonRow: View {
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(AppColors.elevated(colorScheme)).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 7) {
                Bone(width: 150, height: 12, colorScheme: colorScheme)
                Bone(width: 220, height: 10, colorScheme: colorScheme)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .shimmering()
    }
}

/// `count` skeleton post cards, for a feed or profile's first load.
struct SkeletonPostList: View {
    var count = 3
    let colorScheme: ColorScheme

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in SkeletonPostCard(colorScheme: colorScheme) }
        }
    }
}
