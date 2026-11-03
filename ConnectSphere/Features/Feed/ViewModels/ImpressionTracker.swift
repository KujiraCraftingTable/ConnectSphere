import Foundation
import SwiftUI

/// Times how long each post in a feed is at least half on screen, notes the
/// posts the user opens, and sends them in batches — the behaviour feed
/// ranking learns from (FEED_RANKING_REVIEW.md, phase A). Used by the Home
/// feed and community feeds.
@MainActor
final class ImpressionTracker {
    enum Source: String { case home, community }

    private let source: Source
    private let repository = ImpressionRepository()
    /// Posts on screen now, and since when.
    private var onScreen: [String: Date] = [:]
    private var pending: [ImpressionRepository.Item] = []
    private var flushTask: Task<Void, Never>?

    /// Sent this often while scrolling, or sooner once this many pile up.
    private static let flushInterval: Duration = .seconds(10)
    private static let batchSize = 25
    /// Kept for a retry if sending fails, but no more than this.
    private static let maxPending = 100

    init(source: Source) { self.source = source }

    /// A post came at least half on screen, or left it.
    func visibilityChanged(_ postId: String, visible: Bool) {
        if visible {
            if onScreen[postId] == nil { onScreen[postId] = Date() }
        } else {
            end(postId)
        }
    }

    /// The user tapped into the post (or its comments).
    func opened(_ postId: String) {
        add(.init(post_id: postId, view_ms: 0, opened: true))
    }

    /// The feed went off screen or the app went to the background: close every
    /// sighting and send what's waiting.
    func pause() {
        for id in Array(onScreen.keys) { end(id) }
        flush()
    }

    private func end(_ postId: String) {
        guard let start = onScreen.removeValue(forKey: postId) else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard ms > 0 else { return }
        add(.init(post_id: postId, view_ms: ms, opened: false))
    }

    private func add(_ item: ImpressionRepository.Item) {
        pending.append(item)
        trim()
        if pending.count >= Self.batchSize {
            flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.flushInterval)
                guard !Task.isCancelled else { return }
                self?.flushTask = nil
                self?.flush()
            }
        }
    }

    private func trim() {
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        let source = source.rawValue
        let repository = repository
        Task { [weak self] in
            do {
                try await repository.send(source: source, items: batch)
            } catch {
                // Best effort: keep them for the next send (capped).
                self?.pending.insert(contentsOf: batch, at: 0)
                self?.trim()
            }
        }
    }
}

extension View {
    /// Reports to `tracker` while this post is at least half on screen.
    func tracksImpression(_ postId: String, in tracker: ImpressionTracker) -> some View {
        onScrollVisibilityChange(threshold: 0.5) { visible in
            tracker.visibilityChanged(postId, visible: visible)
        }
    }
}
