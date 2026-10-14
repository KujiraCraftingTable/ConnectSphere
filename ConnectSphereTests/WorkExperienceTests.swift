import Foundation
import Testing
@testable import ConnectSphere

/// Work history maths: time in a role, "2 yrs 3 mos", grouping by company.
struct WorkExperienceTests {
    private func role(_ id: String, company: String, companyId: String? = nil, start: String, end: String?) -> WorkExperience {
        let json = """
        {"id":"\(id)","company_id":\(companyId.map { "\"\($0)\"" } ?? "null"),"company_name":"\(company)",
         "company_logo_url":null,"company_verified":false,"title":"T","employment_type":"full_time",
         "location":null,"location_type":null,"start_month":"\(start)","end_month":\(end.map { "\"\($0)\"" } ?? "null"),
         "description":null}
        """
        return try! JSONDecoder().decode(WorkExperience.self, from: Data(json.utf8))
    }

    @Test func spanCountsBothEnds() {
        #expect(WorkMonth.span(from: WorkMonth("2024-03")!, to: WorkMonth("2024-03")!) == 1)
        #expect(WorkMonth.span(from: WorkMonth("2024-01")!, to: WorkMonth("2024-12")!) == 12)
        #expect(WorkMonth.span(from: WorkMonth("2022-01")!, to: WorkMonth("2024-03")!) == 27)
    }

    @Test func durationReadsLikeLinkedIn() {
        let loc = { (s: String) in s }
        #expect(WorkMonth.duration(27, loc: loc) == "2 yrs 3 mos")
        #expect(WorkMonth.duration(12, loc: loc) == "1 yr")
        #expect(WorkMonth.duration(1, loc: loc) == "1 mo")
        #expect(WorkMonth.duration(5, loc: loc) == "5 mos")
    }

    @Test func rolesAtOneCompanyGroupWithTheirTotalTime() {
        let roles = [
            role("a", company: "Acme", companyId: "c1", start: "2024-01", end: "2024-12"),
            role("b", company: "Beta", start: "2021-06", end: "2023-12"),
            role("c", company: "ACME Corp", companyId: "c1", start: "2022-01", end: "2023-12"),
            role("d", company: "beta", start: "2020-01", end: "2021-05"),
        ]
        let groups = WorkExperience.grouped(roles)
        #expect(groups.map(\.roles.count) == [2, 2])           // by page id, and by name ignoring case
        #expect(groups[0].totalMonths == 36)                    // 2022-01 → 2024-12
        #expect(groups[1].totalMonths == 48)                    // 2020-01 → 2023-12
    }

    @Test func monthsAreChecked() {
        #expect(WorkMonth("2024-13") == nil)
        #expect(WorkMonth("2024-03")?.key == "2024-03")
    }
}

/// Skills as the server sends them: most-endorsed first, who vouched, and
/// whether the viewer may endorse.
struct ProfileSkillsTests {
    @Test func decodesSkillsAndWhetherICanEndorse() throws {
        let json = """
        {"data":[{"id":7,"skill":"Swift","endorsement_count":2,"endorsed_by_me":true,
                  "top_endorsers":[{"id":"u1","display_name":"An","avatar_url":null,"avatar_color":"#111111"}]},
                 {"id":8,"skill":"Go","endorsement_count":0,"endorsed_by_me":false,"top_endorsers":[]}],
         "can_endorse":true}
        """
        let result = try JSONDecoder().decode(ProfileSkills.self, from: Data(json.utf8))
        #expect(result.canEndorse)
        #expect(result.data.map(\.skill) == ["Swift", "Go"])
        #expect(result.data[0].endorsedByMe && result.data[0].endorsementCount == 2)
        #expect(result.data[0].topEndorsers.first?.displayName == "An")
    }
}
