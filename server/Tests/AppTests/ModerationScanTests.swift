@testable import App
import XCTest

/// The automatic check's judgement: what the safety model and OpenAI's second
/// opinion add up to, and when content may be hidden before a person looks.
final class ModerationScanTests: XCTestCase {
    private func guardVerdict(_ level: LocalGuard.Level, _ cats: [String] = []) -> LocalGuard.Verdict {
        .init(level: level, categories: cats)
    }

    // MARK: parsing

    func testParsesTheModelsAnswer() {
        XCTAssertEqual(LocalGuard.parse("Safety: Unsafe\nCategories: Violent"),
                       guardVerdict(.unsafe, ["Violent"]))
        XCTAssertEqual(LocalGuard.parse("Safety: Controversial\nCategories: Violent, Suicide & Self-Harm"),
                       guardVerdict(.controversial, ["Violent", "Suicide & Self-Harm"]))
        XCTAssertEqual(LocalGuard.parse("Safety: Safe\nCategories: None"), guardVerdict(.safe))
        XCTAssertEqual(LocalGuard.parse("  safety: safe  \n"), guardVerdict(.safe))
        XCTAssertNil(LocalGuard.parse("I cannot help with that"))
        XCTAssertNil(LocalGuard.parse(""))
    }

    func testOnlyCategoriesThatAreRulesHereCount() {
        XCTAssertEqual(LocalGuard.policy(for: "Violent"), .violence)
        XCTAssertEqual(LocalGuard.policy(for: "Suicide & Self-Harm"), .selfHarm)
        XCTAssertEqual(LocalGuard.policy(for: "Sexual Content or Sexual Acts"), .nuditySexual)
        for ignored in ["PII", "Politically Sensitive Topics", "Copyright Violation", "Jailbreak", "Whatever"] {
            XCTAssertNil(LocalGuard.policy(for: ignored), ignored)
        }
    }

    func testParsesOpenAIsAnswer() throws {
        let json = #"{"results":[{"flagged":true,"categories":{"harassment":true,"violence":false,"hate":true},"category_scores":{"harassment":0.91}}]}"#
        let r = try XCTUnwrap(OpenAIModeration.parse(Data(json.utf8)))
        XCTAssertTrue(r.flagged)
        XCTAssertEqual(r.categories, ["harassment", "hate"])
        XCTAssertEqual(r.scores["harassment"], 0.91)
        XCTAssertNil(OpenAIModeration.parse(Data("{}".utf8)))
        XCTAssertEqual(OpenAIModeration.policy(for: "sexual/minors"), .childSafety)
        XCTAssertEqual(OpenAIModeration.policy(for: "harassment/threatening"), .violence)
        XCTAssertNil(OpenAIModeration.policy(for: "something-new"))
    }

    // MARK: deciding

    func testSafeIsLeftAlone() {
        XCTAssertNil(ModerationScan.decide(guardVerdict: guardVerdict(.safe), openAI: nil))
    }

    func testUnsafeSevereHarmHidesButMilderHarmOnlyFlags() {
        let violent = ModerationScan.decide(guardVerdict: guardVerdict(.unsafe, ["Violent"]), openAI: nil)
        XCTAssertEqual(violent, .init(policy: .violence, hide: true, source: "guard"))
        let insult = ModerationScan.decide(guardVerdict: guardVerdict(.unsafe, ["Unethical Acts"]), openAI: nil)
        XCTAssertEqual(insult?.policy, .harassment)
        XCTAssertEqual(insult?.hide, false)   // severity 2: a person decides, the post stays up
    }

    func testTheMostSevereCategoryWins() {
        let f = ModerationScan.decide(guardVerdict: guardVerdict(.unsafe, ["Unethical Acts", "Suicide & Self-Harm"]), openAI: nil)
        XCTAssertEqual(f?.policy, .selfHarm)
    }

    func testUnsafeAboutNothingWeCareAboutIsIgnored() {
        XCTAssertNil(ModerationScan.decide(guardVerdict: guardVerdict(.unsafe, ["Politically Sensitive Topics"]), openAI: nil))
        XCTAssertNil(ModerationScan.decide(guardVerdict: guardVerdict(.unsafe), openAI: nil))
    }

    func testControversialNeverHidesOnItsOwn() {
        let f = ModerationScan.decide(guardVerdict: guardVerdict(.controversial, ["Violent"]), openAI: nil)
        XCTAssertEqual(f, .init(policy: .violence, hide: false, source: "guard"))
    }

    func testASecondOpinionDecidesAnUnsureOne() {
        let unsure = guardVerdict(.controversial, ["Violent"])
        let clear = OpenAIModeration.Result(flagged: false, categories: [], scores: [:])
        XCTAssertNil(ModerationScan.decide(guardVerdict: unsure, openAI: clear))
        let threat = OpenAIModeration.Result(flagged: true, categories: ["harassment/threatening"], scores: [:])
        XCTAssertEqual(ModerationScan.decide(guardVerdict: unsure, openAI: threat),
                       .init(policy: .violence, hide: true, source: "guard+openai"))
        let rude = OpenAIModeration.Result(flagged: true, categories: ["harassment"], scores: [:])
        XCTAssertEqual(ModerationScan.decide(guardVerdict: unsure, openAI: rude)?.hide, false)
    }

    func testScamLookingTextIsHeldOnlyFromNewAccounts() {
        let text = "Kiếm tiền online, lãi suất cao, hoa hồng mỗi ngày"
        XCTAssertEqual(ModerationScan.scamFinding(text: text, isNewAccount: true), .init(policy: .scam, hide: true, source: "rules"))
        XCTAssertEqual(ModerationScan.scamFinding(text: text, isNewAccount: false)?.hide, false)
        XCTAssertNil(ModerationScan.scamFinding(text: "Mai đi cà phê không?", isNewAccount: true))
    }

    func testTheMoreSevereFindingWins() {
        let scam = ModerationScan.Finding(policy: .scam, hide: true, source: "rules")
        let insult = ModerationScan.Finding(policy: .harassment, hide: false, source: "guard")
        XCTAssertEqual(ModerationScan.moreSevere(insult, scam), scam)
        XCTAssertEqual(ModerationScan.moreSevere(scam, nil), scam)
        XCTAssertNil(ModerationScan.moreSevere(nil, nil))
    }
}
