import SwiftUI

// MARK: - Card
/// "Mini CV" for AI search results. Replaces the regular user card when searching with Kujira.
/// Part 1: round avatar + name + bio (fallback when empty) + match % badge on the right.
/// Part 2: up to 5 "why it matched" bullets, formatted from the match_evidence the backend
/// already returns, no extra LLM call on the client.
struct MiniCVCard: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme
    let user: UserProfile
    let evidence: [MatchEvidenceDTO]
    /// "Why they fit you", arrives a moment after the results.
    var fitReason: String? = nil
    var onOpen: () -> Void = {}

    /// Bullets to display: drop the "profile" type since the bio already appears in part 1 of the card.
    private var displayEvidence: [MatchEvidenceDTO] {
        evidence.filter { $0.type != "profile" }
    }

    /// Match % = similarity of the best-matching chunk (includes the profile chunk even though it has no bullet).
    private var matchPercent: Int? {
        guard let best = evidence.compactMap({ $0.similarity }).max() else { return nil }
        return Int((best * 100).rounded())
    }

    var body: some View {
        NavigationLink(destination: UserProfileView(userId: user.id, preloadedUser: user)
            .environment(appState)) {
            VStack(alignment: .leading, spacing: 12) {
                // ── Part 1: avatar + name + bio + % badge ──
                HStack(alignment: .top, spacing: 12) {
                    AvatarView(user: user, size: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name)
                            .scaledFont(17, .semibold)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        if user.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("This user hasn't shared anything about themselves yet", bundle: bundle)
                                .scaledFont(13)
                                .italic()
                                .foregroundColor(AppColors.textSecondary(colorScheme).opacity(0.8))
                        } else {
                            // Long bio wraps to as many lines as needed, not truncated with "…"
                            Text(user.bio)
                                .scaledFont(13)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    if let percent = matchPercent {
                        MatchPercentBadge(percent: percent)
                    }
                }

                if let fitReason {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .scaledFont(12)
                            .foregroundColor(themeManager.theme.primary)
                            .frame(width: 16)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fitReason)
                                .scaledFont(13, .medium)
                                .foregroundColor(AppColors.textPrimary(colorScheme))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            // AI Law 134/2025 Art. 11: AI-written text is marked as such.
                            Text(bundle.loc("AI-generated"))
                                .scaledFont(11)
                                .foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }

                // ── Part 2: match reasons ──
                if !displayEvidence.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(displayEvidence.prefix(5), id: \.self) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: item))
                                    .scaledFont(12)
                                    .foregroundColor(themeManager.theme.primary)
                                    .frame(width: 16)
                                    .padding(.top, 1)
                                Text(reasonText(for: item))
                                    .scaledFont(13)
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
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
    }

    // MARK: - Evidence text
    /// Icon based on evidence type: profile / post / engagement / community.
    private func icon(for item: MatchEvidenceDTO) -> String {
        switch item.type {
        case "post":       return "text.bubble"
        case "engagement": return "heart.text.square"
        case "community": return "person.3"
        default:          return "person.text.rectangle"
        }
    }

    /// Format one evidence item into a localized reason sentence (pure template, no LLM).
    /// The % is no longer part of the sentence, it's been moved to the badge on the card's right side.
    private func reasonText(for item: MatchEvidenceDTO) -> String {
        let terms = item.matchedTerms.prefix(2).joined(separator: ", ")

        switch item.type {
        case "post":
            let count = item.postCount ?? 1
            if count > 1 { return multiPostText(for: item, count: count, terms: terms) }

            // Single post, single-item format with "how long ago"
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

        case "engagement":
            return engagementText(for: item, terms: terms)

        case "community":
            return String(format: bundle.loc("Member of the \"%@\" community"), item.communityName ?? "")

        default:
            return bundle.loc("Closely matches your search")
        }
    }

    /// Reacted to posts matching the search. Names only public actions,
    /// comments, then shares. Likes are private in the app, so a like-only
    /// match reads "Engages with…" and never says what they liked.
    private func engagementText(for item: MatchEvidenceDTO, terms: String) -> String {
        let subject = item.topic.flatMap { $0.isEmpty ? nil : $0 } ?? (terms.isEmpty ? nil : terms)
        let comments = item.commentedCount ?? 0
        let shares = item.sharedCount ?? 0
        guard let subject else {
            if comments > 0 { return bundle.loc("Commented on posts related to your search") }
            if shares > 0 { return bundle.loc("Shared posts related to your search") }
            return bundle.loc("Engages with posts related to your search")
        }
        if comments == 1 { return String(format: bundle.loc("Commented on a post about %@"), subject) }
        if comments > 1 { return String(format: bundle.loc("Commented on %d posts about %@"), comments, subject) }
        if shares == 1 { return String(format: bundle.loc("Shared a post about %@"), subject) }
        if shares > 1 { return String(format: bundle.loc("Shared %d posts about %@"), shares, subject) }
        return String(format: bundle.loc("Engages with posts about %@"), subject)
    }

    /// Multiple posts on the same topic, merged: "N posts about X in the last 7 days".
    /// The time window is computed from the OLDEST post in the group so the sentence stays accurate.
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

// MARK: - Match badge
/// How closely someone's profile matches yours (vector similarity × 100),
/// the same number on AI search results and People you may know.
struct MatchPercentBadge: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    let percent: Int

    var body: some View {
        Text("\(percent)%")
            .scaledFont(12, .semibold)
            .foregroundColor(themeManager.theme.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(themeManager.theme.primary.opacity(0.12)))
            .accessibilityLabel(Text(String(format: bundle.loc("%lld%% match"), percent)))
    }
}
