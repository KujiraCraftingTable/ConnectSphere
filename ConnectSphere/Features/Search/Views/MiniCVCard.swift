import SwiftUI

/// "Mini CV" cho kết quả AI search — thay user card thường khi search bằng Kujira.
/// Phần 1: avatar tròn + tên + bio (fallback khi trống) + badge % phù hợp góc phải.
/// Phần 2: tối đa 5 bullet "vì sao khớp" — format từ match_evidence backend trả sẵn,
/// không gọi thêm LLM ở client.
struct MiniCVCard: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    let user: UserProfile
    let evidence: [MatchEvidenceDTO]

    /// Bullet hiển thị: bỏ loại "profile" vì bio đã nằm ngay phần 1 của card.
    private var displayEvidence: [MatchEvidenceDTO] {
        evidence.filter { $0.type != "profile" }
    }

    /// % phù hợp = similarity của chunk khớp nhất (tính cả profile chunk dù không hiện bullet).
    private var matchPercent: Int? {
        guard let best = evidence.compactMap({ $0.similarity }).max() else { return nil }
        return Int((best * 100).rounded())
    }

    var body: some View {
        NavigationLink(destination: UserProfileView(userId: user.id, preloadedUser: user)
            .environment(appState)) {
            VStack(alignment: .leading, spacing: 12) {
                // ── Phần 1: avatar + tên + bio + badge % ──
                HStack(alignment: .top, spacing: 12) {
                    AvatarView(user: user, size: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        if user.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("This user hasn't shared anything about themselves yet", bundle: bundle)
                                .font(.system(size: 13))
                                .italic()
                                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.8))
                        } else {
                            // Bio dài thì xuống dòng đủ, không cắt "…"
                            Text(user.bio)
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    if let percent = matchPercent {
                        Text("\(percent)%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(themeManager.theme.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(themeManager.theme.primary.opacity(0.12)))
                    }
                }

                // ── Phần 2: lý do khớp ──
                if !displayEvidence.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(displayEvidence.prefix(5), id: \.self) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: item))
                                    .font(.system(size: 12))
                                    .foregroundColor(themeManager.theme.primary)
                                    .frame(width: 16)
                                    .padding(.top, 1)
                                Text(reasonText(for: item))
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textPrimary(colorScheme))
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// Icon theo loại evidence: hồ sơ / bài viết / cộng đồng.
    private func icon(for item: MatchEvidenceDTO) -> String {
        switch item.type {
        case "post":      return "text.bubble"
        case "community": return "person.3"
        default:          return "person.text.rectangle"
        }
    }

    /// Format một evidence thành câu lý do đã localize (template thuần, không LLM).
    /// % không nằm trong câu nữa — đã dời lên badge góc phải của card.
    private func reasonText(for item: MatchEvidenceDTO) -> String {
        let terms = item.matchedTerms.prefix(2).joined(separator: ", ")

        switch item.type {
        case "post":
            let count = item.postCount ?? 1
            if count > 1 { return multiPostText(for: item, count: count, terms: terms) }

            // 1 bài — format đơn lẻ kèm "bao lâu trước"
            let when = item.latestPostAt?.timeAgoString
            if let topic = item.topic, !topic.isEmpty {
                if let when {
                    return String(format: bundle.loc("Posted about %@ (%@)"), topic, when)
                }
                return String(format: bundle.loc("Has posts about %@"), topic)
            }
            if !terms.isEmpty {
                return String(format: bundle.loc("Has a post mentioning %@"), terms)
            }
            return bundle.loc("Has a post closely related to your search")

        case "community":
            return String(format: bundle.loc("Member of the \"%@\" community"), item.communityName ?? "")

        default:
            return bundle.loc("Closely matches your search")
        }
    }

    /// Nhiều bài cùng topic đã gộp: "Có N bài viết về X trong 7 ngày qua".
    /// Cụm thời gian tính từ bài CŨ NHẤT trong nhóm để câu nói đúng sự thật.
    private func multiPostText(for item: MatchEvidenceDTO, count: Int, terms: String) -> String {
        enum Window { case week, month, none }
        let window: Window = {
            guard let oldest = item.oldestPostAt else { return .none }
            let age = -oldest.timeIntervalSinceNow
            if age <= 7  * 86400 { return .week }
            if age <= 30 * 86400 { return .month }
            return .none
        }()

        if let topic = item.topic, !topic.isEmpty {
            switch window {
            case .week:  return String(format: bundle.loc("Has %d posts about %@ in the last 7 days"), count, topic)
            case .month: return String(format: bundle.loc("Has %d posts about %@ in the last month"), count, topic)
            case .none:  return String(format: bundle.loc("Has %d posts about %@"), count, topic)
            }
        }
        if !terms.isEmpty {
            return String(format: bundle.loc("Has %d posts mentioning %@"), count, terms)
        }
        return String(format: bundle.loc("Has %d posts closely related to your search"), count)
    }
}
