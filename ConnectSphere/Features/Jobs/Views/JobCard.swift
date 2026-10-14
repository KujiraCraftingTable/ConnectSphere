import SwiftUI

/// A job in a list: company logo, title, company (✓), pay, place · format,
/// level, why it fits you, and Save.
struct JobCard: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let job: JobListing
    var showsMatch = true
    let onToggleSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(name: job.companyName ?? job.poster.displayName,
                       imageURL: job.companyLogoUrl ?? job.poster.avatarUrl, size: .md, shape: .roundedSquare)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Text(job.companyName ?? job.poster.displayName)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                            .lineLimit(1)
                        if job.companyVerified { OfficialBadge(compact: true) }
                    }
                }
                Spacer(minLength: 4)
                Button(action: onToggleSave) {
                    Image(systemName: job.saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 18))
                        .foregroundColor(job.saved ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(bundle.loc(job.saved ? "Saved" : "Save")))
            }
            Text(job.salaryText(loc: bundle.loc) ?? bundle.loc("Negotiable"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(themeManager.theme.primary)
            let facts = [job.location, job.workFormat.map { bundle.loc(JobListing.formatLabel($0)) },
                         job.level.map { bundle.loc(JobListing.levelLabel($0)) },
                         job.employmentType.flatMap(EmploymentType.init(rawValue:)).map { bundle.loc($0.label) }]
                .compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if showsMatch && !job.isMine {
                    Label(job.matchText(loc: bundle.loc), systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.theme.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(themeManager.theme.primary.opacity(0.1), in: Capsule())
                }
                Spacer(minLength: 0)
                if let deadline = job.deadlineDate {
                    Text(String(format: bundle.loc("Until %@"), deadline.formatted(.dateTime.day().month(.abbreviated))))
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                }
            }
        }
        .padding(14)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}
