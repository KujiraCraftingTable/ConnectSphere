import SwiftUI

/// A post shared into a chat: the author, a few lines of the text, then the
/// first photo below them, tappable to open the post. It's loaded as the viewer (see
/// `ChatViewModel.loadSharedPost`), so a post they're not allowed to see,
/// friends only, from someone they're not friends with, or one since
/// deleted shows as unavailable instead.
///
/// Shared by the full chat (`MessageBubble`) and the floating window
/// (`compact`).
struct ChatSharedPostCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    let state: ChatViewModel.SharedPostState?
    var compact = false
    /// The chat theme's colour, for the thin outline that sets the post apart.
    let accent: Color
    let onAppear: () -> Void
    let onOpen: (Post) -> Void

    // MARK: - Body
    var body: some View {
        Group {
            switch state {
            case .loaded(let post):
                // A tap, not a Button: a Button still fires when a swipe-to-reply
                // ends over it (the card slides with the finger), while a tap
                // gesture gives up as soon as the finger moves.
                Group { if compact { row(post) } else { card(post) } }
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(post) }
                    .accessibilityAddTraits(.isButton)
            case .unavailable:
                unavailable
            case .loading, nil:
                RoundedRectangle(cornerRadius: corner)
                    .fill(AppColors.surface(colorScheme))
                    .frame(height: compact ? 68 : 120)
                    .overlay { ProgressView() }
                    .overlay(outline)
            }
        }
        .frame(maxWidth: compact ? .infinity : 280, alignment: .leading)
        .onAppear(perform: onAppear)
    }

    private var corner: CGFloat { compact ? 12 : 14 }

    private var outline: some View {
        RoundedRectangle(cornerRadius: corner).stroke(accent.opacity(0.6), lineWidth: 1)
    }

    // MARK: - Row
    /// The floating window's version: two short lines and the first photo on the right, so a few
    /// shared posts still leave room to tap the window and reply.
    private func row(_ post: Post) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    AvatarView(user: post.author, size: 16)
                    Text(post.author.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                }
                let text = post.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                }
                if let kind = kindLabel(post) {
                    Label(kind.0, systemImage: kind.1)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let first = post.imageUrls.first.flatMap(APIConfig.mediaURL) {
                ZStack {
                    AsyncImage(url: first) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(AppColors.elevated(colorScheme))
                        }
                    }
                    if Self.isVideo(first) {
                        Rectangle().fill(Color.black.opacity(0.85))
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(8)
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(outline)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(bundle.loc("Opens the post")))
    }

    // MARK: - Card
    private func card(_ post: Post) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AvatarView(user: post.author, size: compact ? 18 : 22)
                    Text(post.author.name)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(1)
                }
                let text = post.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: compact ? 12 : 14))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if let kind = kindLabel(post) {
                    Label(kind.0, systemImage: kind.1)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
            .padding(compact ? 8 : 10)
            if let first = post.imageUrls.first.flatMap(APIConfig.mediaURL) {
                ZStack {
                    AsyncImage(url: first) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(AppColors.elevated(colorScheme))
                        }
                    }
                    if Self.isVideo(first) {
                        Rectangle().fill(Color.black.opacity(0.85))
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: compact ? 24 : 30))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .frame(height: compact ? 110 : 150)
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(outline)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(bundle.loc("Opens the post")))
    }

    private var unavailable: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
            Text("This post isn't available", bundle: bundle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: compact ? 12 : 13))
        .foregroundColor(AppColors.textSecondary(colorScheme))
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: corner))
        .overlay(outline)
    }

    // MARK: - Helpers
    private func kindLabel(_ post: Post) -> (String, String)? {
        switch post.postType {
        case .poll:  return (bundle.loc("Poll"), "chart.bar.fill")
        case .event: return (bundle.loc("Event"), "calendar")
        case .job:   return (bundle.loc("Job"), "briefcase.fill")
        case .listing:
            // The listing a buyer sent with "Message seller": what it's about at a glance.
            return (post.listingData.map { $0.priceText(loc: bundle.loc) + " · " + $0.title } ?? bundle.loc("Listing"), "bag.fill")
        case .legit: return (bundle.loc("Reviews"), "checkmark.seal.fill")
        case .text:  return nil
        }
    }

    private static func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov"].contains(url.pathExtension.lowercased())
    }
}
