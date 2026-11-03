@testable import App
import XCTest

/// Background Ollama work waits for user-facing calls and runs one at a time.
final class OllamaGateTests: XCTestCase {
    actor Log {
        var events: [String] = []
        func add(_ e: String) { events.append(e) }
    }

    func testBackgroundWaitsForAUserCall() async throws {
        let log = Log()
        let user = Task {
            try await OllamaGate.run {
                await log.add("user start")
                try await Task.sleep(for: .milliseconds(200))
                await log.add("user end")
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        try await OllamaGate.$isBackground.withValue(true) {
            try await OllamaGate.run { await log.add("background") }
        }
        try await user.value
        let events = await log.events
        XCTAssertEqual(events, ["user start", "user end", "background"])
    }

    func testBackgroundCallsRunOneAtATime() async throws {
        let log = Log()
        try await OllamaGate.$isBackground.withValue(true) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<3 {
                    group.addTask {
                        try await OllamaGate.run {
                            await log.add("start \(i)")
                            try await Task.sleep(for: .milliseconds(40))
                            await log.add("end \(i)")
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        let events = await log.events
        // Each start is immediately followed by its own end.
        for k in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[k].replacingOccurrences(of: "start", with: "end"), events[k + 1])
        }
    }
}
