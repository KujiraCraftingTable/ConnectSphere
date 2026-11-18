import Foundation
import Observation

/// "People you may know" for the feed: suggestions per mode, where the module
/// sits in the current load, and the Connect / dismiss actions on its cards.
@MainActor
@Observable
final class PeopleSuggestionsViewModel {
    private(set) var suggestions: [AppMode: [PeopleSuggestion]] = [:]
    /// Requests sent from a card this session. The card shows "Requested".
    private(set) var requested: Set<String> = []
    private(set) var sending: Set<String> = []
    var error: String?

    /// Whether this load opened with suggestions you hadn't seen. Decided at
    /// load time, so marking them seen doesn't move the module mid-scroll.
    private var openedFresh: [AppMode: Bool] = [:]
    private var seeds: [AppMode: UInt64] = [:]

    private let repository = SuggestionRepository()
    private let defaults = AppDefaults.store
    /// Seen ids are kept per device (a convenience, not something to sync),
    /// capped so the list can't grow without bound.
    private static let maxRemembered = 500

    func suggestions(for mode: AppMode) -> [PeopleSuggestion] { suggestions[mode] ?? [] }

    /// Reload for `mode`: called with every feed reload (pull to refresh,
    /// mode or tab switch, tapping Home again).
    func refresh(_ mode: AppMode) async {
        do {
            let list = try await repository.list(mode: mode)
            suggestions[mode] = list
            let seen = seenIds(mode)
            openedFresh[mode] = list.contains { !seen.contains($0.id.lowercased()) }
            seeds[mode] = UInt64.random(in: 0...UInt64.max)
        } catch {
            // The feed works without the module. No alert for a failed extra.
            if suggestions[mode] == nil { suggestions[mode] = [] }
        }
    }

    /// Indices in the post list the module goes before (see `SuggestionPlacement`).
    func slots(for mode: AppMode, postCount: Int) -> [Int] {
        SuggestionPlacement.slots(isFresh: openedFresh[mode] ?? false, postCount: postCount,
                                  suggestionCount: suggestions(for: mode).count, seed: seeds[mode] ?? 0)
    }

    /// The cards for the n-th appearance in a load: the second one starts
    /// further along, so it isn't the same faces again.
    func cards(for mode: AppMode, appearance: Int) -> [PeopleSuggestion] {
        let list = suggestions(for: mode)
        guard appearance > 0, list.count > 6 else { return list }
        return Array(list[6...] + list[..<6])
    }

    func markSeen(_ mode: AppMode) {
        var seen = seenIds(mode)
        seen.formUnion(suggestions(for: mode).map { $0.id.lowercased() })
        defaults.set(Array(seen.prefix(Self.maxRemembered)), forKey: Self.seenKey(mode))
    }

    func dismiss(_ person: PeopleSuggestion, mode: AppMode) async {
        let before = suggestions(for: mode)
        suggestions[mode] = before.filter { $0.id != person.id }   // optimistic
        do {
            try await repository.dismiss(person.id, mode: mode)
        } catch {
            suggestions[mode] = before
            self.error = Bundle.app.loc(friendlyError(error))
        }
    }

    func connect(_ person: PeopleSuggestion, mode: AppMode) async {
        guard !requested.contains(person.id), !sending.contains(person.id) else { return }
        sending.insert(person.id)
        defer { sending.remove(person.id) }
        do {
            try await repository.sendRequest(to: person.id, mode: mode)
            requested.insert(person.id)
        } catch {
            self.error = Bundle.app.loc(friendlyError(error))
        }
    }

    private func seenIds(_ mode: AppMode) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.seenKey(mode)) ?? [])
    }

    private static func seenKey(_ mode: AppMode) -> String { "peopleSuggestionsSeen.\(mode.rawValue)" }
}
