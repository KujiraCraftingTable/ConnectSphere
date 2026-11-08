import Vapor

/// `swift run App moderation-eval server/Tests/Fixtures/moderation_eval.jsonl [--model <ollama model>] [--list]`
///
/// Runs the automatic text checks over a hand-labelled set and reports, per
/// rule, how much harm they catch and how much ordinary text they wrongly
/// flag or would hide. This is what decides whether `MODERATION_MODE` can
/// move from `shadow` to `enforce`, and whether the 0.6B or the 4B model is
/// worth its memory. Each line of the file: `{"text", "expect": "safe"|"harmful",
/// "policy": "violence"|…|"none", "note"}`. OpenAI's second opinion isn't
/// called: items the model is unsure about are counted as "unsure".
struct ModerationEvalCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "file", help: "JSON-lines evaluation set.") var file: String
        @Option(name: "model", help: "Guard model to try (default: MODERATION_GUARD_MODEL).") var model: String?
        @Flag(name: "list", help: "Also list every wrongly flagged and every missed item.") var list: Bool
    }

    var help: String { "Scores the automatic text checks against a labelled set." }

    struct Item: Decodable { let text: String; let expect: String; let policy: String; let note: String? }

    struct Result {
        let item: Item
        let rules: ModerationRules.Verdict
        let guardVerdict: LocalGuard.Verdict?
        let finding: ModerationScan.Finding?
        var isSafe: Bool { item.expect == "safe" }
        var ruleCaught: Bool { rules != .clean }
        var flagged: Bool { finding != nil }
        var unsure: Bool { guardVerdict?.level == .controversial && finding == nil }
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console
        guard let text = try? String(contentsOfFile: signature.file, encoding: .utf8) else {
            console.error("Can't read \(signature.file)"); return
        }
        let items = try text.split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(Item.self, from: Data($0.utf8))
        }
        let model = signature.model ?? app.appEnv.moderation.guardModel
        console.info("\(items.count) items, guard model: \(model)")

        var results: [Result] = []
        let started = Date()
        for (i, item) in items.enumerated() {
            let rules = ModerationRules.verdict(item.text)
            var verdict: LocalGuard.Verdict?
            do { verdict = try await LocalGuard.classify(item.text, model: model, ollama: app.ollama) }
            catch { console.warning("guard failed on item \(i + 1): \(error)") }
            let finding = verdict.flatMap { ModerationScan.decide(guardVerdict: $0, openAI: nil) }
            let scam = ModerationScan.scamFinding(text: item.text, isNewAccount: false)
            results.append(Result(item: item, rules: rules, guardVerdict: verdict,
                                  finding: ModerationScan.moreSevere(finding, scam)))
            if (i + 1) % 50 == 0 { console.info("  … \(i + 1)/\(items.count)") }
        }
        let secs = Date().timeIntervalSince(started)
        console.info(String(format: "%.1f s total, %.2f s per item", secs, secs / Double(max(1, items.count))))
        report(results, console: console, list: signature.list)
    }

    private func pct(_ n: Int, _ of: Int) -> String {
        of == 0 ? "-" : String(format: "%d/%d (%.0f%%)", n, of, 100 * Double(n) / Double(of))
    }

    private func isBlocked(_ r: Result) -> Bool {
        if case .block = r.rules { return true }
        return false
    }

    private func report(_ results: [Result], console: any Console, list: Bool) {
        let safe = results.filter(\.isSafe), harmful = results.filter { !$0.isSafe }
        console.info("")
        console.info("ORDINARY TEXT (\(safe.count))")
        console.info("  flagged for review     \(pct(safe.filter(\.flagged).count, safe.count))")
        console.info("  would be HIDDEN        \(pct(safe.filter { $0.finding?.hide == true }.count, safe.count))   <- must stay near 0 before 'enforce'")
        console.info("  unsure (to OpenAI)     \(pct(safe.filter(\.unsure).count, safe.count))")
        console.info("  word rules: nudge      \(pct(safe.filter { $0.rules == .nudge }.count, safe.count))   refused \(pct(safe.filter(isBlocked).count, safe.count))")
        console.info("")
        console.info("HARMFUL TEXT (\(harmful.count))      caught by: rules | AI | either      hidden   right rule")
        for policy in Set(harmful.map(\.item.policy)).sorted() {
            let g = harmful.filter { $0.item.policy == policy }
            let either = g.filter { $0.ruleCaught || $0.flagged }.count
            let rightPolicy = g.filter { $0.finding?.policy.rawValue == policy }.count
            let name = policy.padding(toLength: 14, withPad: " ", startingAt: 0)
            console.info("  \(name) n=\(g.count)   \(pct(g.filter(\.ruleCaught).count, g.count)) | \(pct(g.filter(\.flagged).count, g.count)) | \(pct(either, g.count))   hidden \(g.filter { $0.finding?.hide == true }.count)   \(rightPolicy)")
        }
        let caught = harmful.filter { $0.ruleCaught || $0.flagged }.count
        console.info("  all            n=\(harmful.count)   either: \(pct(caught, harmful.count))   hidden: \(pct(harmful.filter { $0.finding?.hide == true }.count, harmful.count))")
        guard list else { return }
        console.info("")
        console.info("WRONGLY FLAGGED")
        for r in safe where r.flagged {
            console.info("  [\(r.finding!.policy.rawValue)\(r.finding!.hide ? ", hide" : "")] \(r.item.text)")
        }
        console.info("MISSED (no rule, no AI finding)")
        for r in harmful where !r.ruleCaught && !r.flagged {
            let seen = r.guardVerdict.map { "\($0.level.rawValue) \($0.categories)" } ?? "failed"
            console.info("  [\(r.item.policy), guard: \(seen)] \(r.item.text)")
        }
    }
}
