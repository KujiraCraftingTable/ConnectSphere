import SwiftUI
import Charts

/// Line chart showing member count OR post count over time
/// Uses Swift Charts (iOS 16+, available on iOS 26.5 target)
struct GrowthChart: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle
    let snapshots:    [DailySnapshot]
    @Binding var showMembers: Bool   // true = member count, false = post count
    var accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Toggle
            Picker("Metric", selection: $showMembers) {
                Text("Members", bundle: bundle).tag(true)
                Text("Posts", bundle: bundle).tag(false)
            }
            .pickerStyle(.segmented)

            if snapshots.isEmpty {
                noDataPlaceholder
            } else {
                Chart {
                    ForEach(snapshots.indices, id: \.self) { i in
                        let snapshot = snapshots[i]
                        let y = showMembers ? snapshot.memberCount : snapshot.postCount

                        LineMark(
                            x: .value("Date", i),
                            y: .value(showMembers ? "Members" : "Posts", y)
                        )
                        .foregroundStyle(accentColor)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Date", i),
                            yStart: .value("Base", 0),
                            yEnd:   .value(showMembers ? "Members" : "Posts", y)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [accentColor.opacity(0.25), accentColor.opacity(0.0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
                }
                .chartXAxis {
                    AxisMarks(values: xAxisStride) { value in
                        if let idx = value.as(Int.self), idx < snapshots.count {
                            AxisValueLabel { Text(snapshots[idx].shortLabel).font(.caption2) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(v >= 1000 ? "\(v / 1000)k" : "\(v)").font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(14)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Show ~5 x-axis labels spaced evenly
    private var xAxisStride: [Int] {
        guard snapshots.count > 1 else { return [0] }
        let step = max(1, snapshots.count / 5)
        return stride(from: 0, to: snapshots.count, by: step).map { $0 }
    }

    private var noDataPlaceholder: some View {
        Text("No data yet for this period", bundle: bundle)
            .font(.system(size: 14))
            .foregroundColor(AppColors.textTertiary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 180)
    }
}
