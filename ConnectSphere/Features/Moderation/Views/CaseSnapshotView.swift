import SwiftUI

/// What was reported, as it looked then: its text and photos, and for a
/// message the sender's earlier messages that came with the report.
struct CaseSnapshotView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    let snapshot: CaseSnapshot
    var showsEarlierMessages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = snapshot.title {
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            if let username = snapshot.username {
                Text(verbatim: "@\(username)")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
            }
            if let text = snapshot.text {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            if !snapshot.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(snapshot.images, id: \.self) { link in
                            RemoteImage(url: APIConfig.mediaURL(link), maxPixelSize: 400) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    AppColors.elevated(colorScheme)
                                }
                            }
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            if showsEarlierMessages && !snapshot.earlier.isEmpty {
                Text("Earlier messages from this person", bundle: bundle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .padding(.top, 4)
                ForEach(Array(snapshot.earlier.enumerated()), id: \.offset) { _, line in
                    Text(line.content ?? bundle.loc(line.type == "text" ? "" : "Photo, video or voice message"))
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            if snapshot.text == nil && snapshot.title == nil && snapshot.images.isEmpty {
                Text("Nothing to preview", bundle: bundle)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            }
        }
    }
}
