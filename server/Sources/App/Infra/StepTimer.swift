import Foundation

/// Times the steps of one request, for a single log line saying where the
/// time went ("criteria=1203ms vectors=310ms …"). AI search is mostly waiting
/// on the LLM, and this is how that is measured rather than assumed.
struct StepTimer {
    private var last = DispatchTime.now()
    private let started = DispatchTime.now()
    private(set) var steps: [(name: String, ms: Int)] = []

    /// Closes the step that began at the previous mark (or at creation).
    mutating func mark(_ name: String) {
        let now = DispatchTime.now()
        steps.append((name, Int((now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000)))
        last = now
    }

    var summary: String {
        let total = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        return (["total=\(total)ms"] + steps.map { "\($0.name)=\($0.ms)ms" }).joined(separator: " ")
    }
}
