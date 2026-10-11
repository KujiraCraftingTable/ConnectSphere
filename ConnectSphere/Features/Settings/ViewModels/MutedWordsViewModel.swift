import Foundation
import Observation

/// The user's muted words, one list per mode, plus copying a list across.
@MainActor
@Observable
final class MutedWordsViewModel {
    private(set) var words: [AppMode: [MutedWord]] = [:]
    private(set) var loadedModes: Set<AppMode> = []
    private(set) var isAdding = false
    private(set) var isCopying = false
    var error: String?
    /// One-line confirmation after a copy ("Added 3 words to Work").
    var notice: String?

    static let maxLength = 50

    private let repository = MutedWordsRepository()

    func words(for mode: AppMode) -> [MutedWord] { words[mode] ?? [] }

    func load(_ mode: AppMode) async {
        do {
            words[mode] = try await repository.list(mode: mode)
            loadedModes.insert(mode)
        } catch {
            if !loadedModes.contains(mode) { self.error = Self.message(for: error) }
        }
    }

    /// The text to send, or nil when it can't be muted (empty, too long, or
    /// no letter or digit — the server ignores punctuation when matching).
    static func cleaned(_ text: String) -> String? {
        var word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while word.hasPrefix("#") { word.removeFirst() }
        word = word.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !word.isEmpty, word.count <= maxLength,
              word.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        return word
    }

    /// Re-adding a word the list already has just updates its duration.
    func add(_ text: String, duration: MuteDuration, mode: AppMode) async -> Bool {
        guard let word = Self.cleaned(text) else { return false }
        isAdding = true
        defer { isAdding = false }
        do {
            let added = try await repository.add(word, duration: duration, mode: mode)
            var list = words(for: mode).filter { $0.id != added.id && $0.word.lowercased() != added.word.lowercased() }
            list.insert(added, at: 0)
            words[mode] = list
            NotificationCenter.default.post(name: .mutedWordsChanged, object: nil)
            return true
        } catch {
            self.error = Self.message(for: error)
            return false
        }
    }

    func delete(_ word: MutedWord, mode: AppMode) async {
        let before = words(for: mode)
        words[mode] = before.filter { $0.id != word.id }     // optimistic
        do {
            try await repository.delete(word.id)
            NotificationCenter.default.post(name: .mutedWordsChanged, object: nil)
        } catch {
            words[mode] = before
            self.error = Self.message(for: error)
        }
    }

    /// Copies this mode's list into the other mode; words already there stay.
    func copy(from mode: AppMode) async {
        let target: AppMode = mode == .hobby ? .work : .hobby
        isCopying = true
        defer { isCopying = false }
        do {
            let added = try await repository.copy(from: mode, to: target)
            await load(target)
            NotificationCenter.default.post(name: .mutedWordsChanged, object: nil)
            notice = String(format: Bundle.app.loc(target == .work ? "Added %lld to Work mode" : "Added %lld to Hobby mode"), added)
        } catch {
            self.error = Self.message(for: error)
        }
    }

    /// Server reasons are English keys with Vietnamese entries in the strings files.
    private static func message(for error: Error) -> String {
        Bundle.app.loc(friendlyError(error))
    }
}
