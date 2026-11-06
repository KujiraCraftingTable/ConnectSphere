import SwiftUI

/// Position math for the search-radius track, kept free of SwiftUI so it can be
/// tested directly (`RadiusScaleTests`). Distances map *linearly* onto the
/// first `linearSpan` of the track, 5 km is exactly a sixth of 0–30 km, and
/// the stored value `0` ("no limit") is a separate stop at the far right.
/// The old slider spaced stops by list position, so 5 km sat at 29% of the bar.
enum RadiusScale {
    static let maxKm = 30
    static let minKm = 1
    /// Share of the track used by 0…maxKm; the rest is the gap to "no limit".
    static let linearSpan: Double = 0.88
    static let ticks = [5, 10, 15, 20, 25, 30]

    /// Where `km` sits on the track, 0…1. `0` (no limit) is the far end.
    static func fraction(forKm km: Int) -> Double {
        guard km > 0 else { return 1 }
        return Double(min(km, maxKm)) / Double(maxKm) * linearSpan
    }

    /// The value for a touch at `fraction` along the track: whole kilometres
    /// clamped to `minKm…maxKm`, or `0` (no limit) past the gap's midpoint.
    static func km(forFraction fraction: Double) -> Int {
        if fraction > linearSpan + (1 - linearSpan) / 2 { return 0 }
        let km = Int((max(0, fraction) / linearSpan * Double(maxKm)).rounded())
        return min(max(km, minKm), maxKm)
    }
}

/// Search radius picker drawn on a true-to-scale track. Drawn by hand rather
/// than with `Slider` because the labels must sit exactly under their stops,
/// and the system thumb's inset (a wide glass pill on iOS 26) isn't ours to
/// measure. `km == 0` means no limit. The convention `SearchView` reads.
struct SearchRadiusSlider: View {
    @Binding var km: Int
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    private let thumbSize: CGFloat = 26
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let inset = thumbSize / 2
            let usable = max(1, geo.size.width - thumbSize)
            let x = { (fraction: Double) in inset + CGFloat(fraction) * usable }
            let linearEnd = x(RadiusScale.linearSpan)
            let thumbX = x(RadiusScale.fraction(forKm: km))
            let trackY = thumbSize / 2

            ZStack(alignment: .topLeading) {
                // 0–30 km track.
                Capsule()
                    .fill(AppColors.borderDefault(colorScheme))
                    .frame(width: linearEnd - inset, height: trackHeight)
                    .position(x: (inset + linearEnd) / 2, y: trackY)
                // Dotted gap to "no limit", visibly not part of the distance scale.
                Path { p in
                    p.move(to: CGPoint(x: linearEnd + 6, y: trackY))
                    p.addLine(to: CGPoint(x: x(1) - 4, y: trackY))
                }
                .stroke(AppColors.borderDefault(colorScheme),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5]))
                Circle()
                    .fill(AppColors.borderDefault(colorScheme))
                    .frame(width: 8, height: 8)
                    .position(x: x(1), y: trackY)

                // Fill up to the selection (to the end of the scale for no limit).
                Capsule()
                    .fill(tint)
                    .frame(width: max(trackHeight, min(thumbX, linearEnd) - inset), height: trackHeight)
                    .position(x: (inset + max(inset + trackHeight, min(thumbX, linearEnd))) / 2, y: trackY)

                // Ticks + labels, placed by the same function as the thumb.
                ForEach(RadiusScale.ticks, id: \.self) { tick in
                    let tx = x(RadiusScale.fraction(forKm: tick))
                    Capsule()
                        .fill(AppColors.textTertiary(colorScheme))
                        .frame(width: 1.5, height: 5)
                        .position(x: tx, y: trackY + 10)
                    Text(tick == RadiusScale.maxKm ? "\(tick) km" : "\(tick)")
                        .font(.system(size: 10, weight: tick == km ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundColor(tick == km ? tint : AppColors.textSecondary(colorScheme))
                        .fixedSize()
                        .position(x: tx, y: trackY + 24)
                }
                Text("∞")
                    .font(.system(size: 13, weight: km == 0 ? .bold : .regular))
                    .foregroundColor(km == 0 ? tint : AppColors.textSecondary(colorScheme))
                    .position(x: x(1), y: trackY + 23)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 0.5))
                    .position(x: thumbX, y: trackY)
                    .animation(.snappy(duration: 0.15), value: km)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Double((value.location.x - inset) / usable)
                        let newKm = RadiusScale.km(forFraction: fraction)
                        if newKm != km { km = newKm }
                    }
            )
        }
        .frame(height: thumbSize + 26)
        .sensoryFeedback(.selection, trigger: km) { _, new in
            new == 0 || RadiusScale.ticks.contains(new)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Search radius", bundle: bundle))
        .accessibilityValue(km == 0 ? bundle.loc("Unlimited") : String(format: bundle.loc("%d km"), km))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: km = km == 0 ? 0 : (km >= RadiusScale.maxKm ? 0 : km + 1)
            case .decrement: km = km == 0 ? RadiusScale.maxKm : max(RadiusScale.minKm, km - 1)
            @unknown default: break
            }
        }
    }
}
