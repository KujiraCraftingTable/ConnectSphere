import Foundation

/// One local Ollama serves both people waiting on a screen (AI search, the
/// interest check, post analysis) and background work (embeddings, AI tags,
/// translation sweeps). Left alone, a sweep kept Ollama, and the machine,
/// busy enough that `/auth/me` and the feed took a minute.
///
/// Calls made while `isBackground` is set (jobs and sweeps set it) run one at
/// a time and wait while any user-facing call is in flight. User-facing calls
/// always go straight through.
actor OllamaGate {
    static let shared = OllamaGate()

    /// Set around background work: `OllamaGate.$isBackground.withValue(true) { … }`.
    @TaskLocal static var isBackground = false

    private var userCalls = 0
    private var backgroundBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    static func run<T>(_ work: () async throws -> T) async throws -> T {
        if isBackground {
            await shared.enterBackground()
            do {
                let result = try await work()
                await shared.leaveBackground()
                return result
            } catch {
                await shared.leaveBackground()
                throw error
            }
        }
        await shared.enterUser()
        do {
            let result = try await work()
            await shared.leaveUser()
            return result
        } catch {
            await shared.leaveUser()
            throw error
        }
    }

    private func enterUser() { userCalls += 1 }

    private func leaveUser() {
        userCalls -= 1
        wakeAll()
    }

    private func enterBackground() async {
        while userCalls > 0 || backgroundBusy {
            await withCheckedContinuation { waiting.append($0) }
        }
        backgroundBusy = true
    }

    private func leaveBackground() {
        backgroundBusy = false
        wakeAll()
    }

    /// Every waiter re-checks; the first to run takes the slot again.
    private func wakeAll() {
        let woken = waiting
        waiting = []
        woken.forEach { $0.resume() }
    }
}
