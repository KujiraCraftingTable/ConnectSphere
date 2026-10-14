import Foundation
import Observation

/// Manage account › Activity log: your comments, or your reactions, both modes.
@MainActor
@Observable
final class ActivityLogViewModel {
    static let pageSize = 30

    var tab: ActivityRepository.Tab = .comments
    private(set) var comments: [ActivityItem] = []
    private(set) var reactions: [ActivityItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private var reachedEnd: Set<String> = []
    var errorMessage: String?
    private let repository = ActivityRepository()

    var shown: [ActivityItem] { tab == .comments ? comments : reactions }
    var days: [ActivityGrouping.Day] { ActivityGrouping.byDay(shown) }

    func load(token: String) async {
        isLoading = shown.isEmpty
        defer { isLoading = false }
        do {
            let page = try await repository.page(tab, offset: 0, token: token)
            set(page)
            if page.count < Self.pageSize { reachedEnd.insert(tab.rawValue) } else { reachedEnd.remove(tab.rawValue) }
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// The next page, after the ones shown.
    func loadMore(after item: ActivityItem, token: String) async {
        guard item.id == shown.last?.id, !isLoadingMore, !reachedEnd.contains(tab.rawValue) else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await repository.page(tab, offset: shown.count, token: token) else { return }
        let known = Set(shown.map(\.id))
        set(shown + page.filter { !known.contains($0.id) })
        if page.count < Self.pageSize { reachedEnd.insert(tab.rawValue) }
    }

    private func set(_ items: [ActivityItem]) {
        if tab == .comments { comments = items } else { reactions = items }
    }
}
