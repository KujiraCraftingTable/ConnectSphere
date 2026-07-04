import SwiftUI
import Charts

/// Full analytics dashboard for community admins
struct CommunityAnalyticsView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var viewModel: AnalyticsViewModel
    @State private var showMembers = true    // chart toggle

    let communityId: String
    let coverColor:  String

    init(communityId: String, token: String, coverColor: String) {
        _viewModel      = State(initialValue: AnalyticsViewModel(token: token))
        self.communityId = communityId
        self.coverColor  = coverColor
    }

    private var accent: Color { Color(hex: coverColor) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Period selector
                Picker("Period", selection: $viewModel.selectedPeriod) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if viewModel.isLoading {
                    ProgressView().padding(.top, 40)
                } else if let analytics = viewModel.analytics {
                    // Stat cards grid
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                        StatSummaryCard(
                            title:      "Total Members",
                            value:      analytics.totalMembers.formatted(),
                            growthRate: analytics.memberGrowthRate,
                            icon:       "person.3.fill",
                            accentColor: accent
                        )
                        StatSummaryCard(
                            title:      "Total Posts",
                            value:      analytics.totalPosts.formatted(),
                            growthRate: analytics.postGrowthRate,
                            icon:       "doc.text.fill",
                            accentColor: accent
                        )
                    }
                    .padding(.horizontal, 16)

                    // Growth chart
                    GrowthChart(
                        snapshots:   analytics.dailySnapshots,
                        showMembers: $showMembers,
                        accentColor: accent
                    )
                    .padding(.horizontal, 16)

                    // Top posts
                    if !analytics.topPosts.isEmpty {
                        topPostsSection(analytics.topPosts)
                    }
                } else if let err = viewModel.errorMessage {
                    Text(err)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding(.vertical, 16)
        }
        .appBackground()
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.fetchAnalytics(communityId: communityId) }
        .onChange(of: viewModel.selectedPeriod) { _, _ in
            Task<Void, Never>(name: nil) { await viewModel.fetchAnalytics(communityId: communityId) }
        }
    }

    private func topPostsSection(_ posts: [AnalyticsPost]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Posts This Period")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .padding(.horizontal, 16)

            ForEach(posts) { post in
                topPostRow(post)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func topPostRow(_ post: AnalyticsPost) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(post.content)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Label("\(post.likeCount)", systemImage: "heart")
                    Label("\(post.commentCount)", systemImage: "bubble.right")
                }
                .font(.system(size: 12))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            }
            Spacer()
        }
        .padding(12)
        .surfaceBackground()
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
