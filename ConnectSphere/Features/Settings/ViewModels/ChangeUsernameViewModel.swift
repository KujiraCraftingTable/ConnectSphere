import Foundation

/// Settings › Manage account › Username: a new @username, at most once every
/// six months (the server enforces it; `lockedUntil` only explains it).
@MainActor
@Observable
final class ChangeUsernameViewModel {
    enum Availability: Equatable { case unknown, checking, available, taken, invalid, same }

    var username = "" { didSet { if username != oldValue { scheduleCheck() } } }
    private(set) var availability: Availability = .unknown
    private(set) var isSaving = false
    var errorMessage: String?

    private let repository = AccountRepository()
    private var checkTask: Task<Void, Never>?
    private var current = ""
    private var token: String?

    /// Same format as sign-up (`UsernameRules` on the server).
    static func isValidFormat(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9_]{3,30}$", options: .regularExpression) != nil
    }

    /// Trimmed, lowercased, without a leading `@`, as the server stores it.
    var normalized: String {
        var s = username.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    func start(appState: AppState) {
        current = appState.currentUser?.username ?? ""
        token = appState.authToken
    }

    /// Until then the name can't change; nil when it can now.
    func lockedUntil(_ appState: AppState, now: Date = Date()) -> Date? {
        guard let next = appState.currentUser?.usernameNextChangeAt, next > now else { return nil }
        return next
    }

    var canSave: Bool { availability == .available && !isSaving }

    /// When the name chosen now could next change, for the confirmation.
    var nextChangeIfSavedNow: Date {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: 6, to: Date()) ?? Date()
    }

    private func scheduleCheck() {
        checkTask?.cancel()
        errorMessage = nil
        let name = normalized
        guard !name.isEmpty else { availability = .unknown; return }
        guard Self.isValidFormat(name) else { availability = .invalid; return }
        guard name != current else { availability = .same; return }
        guard let token else { availability = .unknown; return }
        availability = .checking
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let free = try? await AuthService.shared.isUsernameAvailable(name, token: token)
            guard !Task.isCancelled, let self, self.normalized == name else { return }
            self.availability = free == true ? .available : (free == false ? .taken : .unknown)
        }
    }

    /// True once changed; the session user carries the new name and date.
    func save(appState: AppState) async -> Bool {
        guard canSave, let token = appState.authToken else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let user = try await repository.changeUsername(normalized, token: token)
            // Only these two: the rest of `currentUser` is the persona in use.
            appState.currentUser?.username = user.username
            appState.currentUser?.usernameNextChangeAt = user.usernameNextChangeAt
            current = user.username
            return true
        } catch APIError.serverError(403, _) {
            // Changed from another device since this screen loaded; the server's
            // sentence has an English date in it, so say it in our own words.
            errorMessage = Bundle.app.loc("You can change your username only once every 6 months.")
            return false
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
}
