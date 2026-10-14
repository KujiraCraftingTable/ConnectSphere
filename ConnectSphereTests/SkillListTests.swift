import Foundation
import Testing
@testable import ConnectSphere

/// Skills typed one at a time into a SkillTagField.
struct SkillListTests {
    @Test func addsOneSkill() {
        #expect(SkillList.adding(" swift ", to: [], limit: 30) == .init(skills: ["swift"], problem: nil))
    }

    @Test func aCommaSeparatesSkills() {
        #expect(SkillList.adding("Swift, Kotlin,", to: [], limit: 30).skills == ["Swift", "Kotlin"])
    }

    @Test func blanksAreIgnored() {
        #expect(SkillList.adding("   ", to: ["Swift"], limit: 30) == .init(skills: ["Swift"], problem: nil))
    }

    @Test func duplicatesIgnoreCase() {
        let r = SkillList.adding("SWIFT", to: ["Swift"], limit: 30)
        #expect(r.skills == ["Swift"] && r.problem == "You already added SWIFT.")
    }

    @Test func theLimitHolds() {
        let full = (1...10).map { "s\($0)" }
        let r = SkillList.adding("Rust", to: full, limit: 10)
        #expect(r.skills == full && r.problem == "Up to 10 skills.")
    }

    @Test func aLongSkillIsRefused() {
        let r = SkillList.adding(String(repeating: "x", count: 51), to: [], limit: 30)
        #expect(r.skills.isEmpty && r.problem == "Keep each skill under 50 characters.")
    }
}
