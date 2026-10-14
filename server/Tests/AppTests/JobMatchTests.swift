@testable import App
import Vapor
import XCTest

final class JobMatchTests: XCTestCase {
    private func row(title: String = "iOS Engineer", location: String? = "Ho Chi Minh City", format: String? = "hybrid",
                     followed: Bool = false, semantic: Double = 0.5, daysOld: Double = 0) -> JobBoardStore.Row {
        let json = """
        {"id":"j","post_id":"p","title":"\(title)","company_name":null,"company_id":null,"company_logo_url":null,
         "company_verified":false,"location":\(location.map { "\"\($0)\"" } ?? "null"),"employment_type":"full_time",
         "work_format":\(format.map { "\"\($0)\"" } ?? "null"),"level":null,"salary_min":null,"salary_max":null,
         "salary_range":null,"application_deadline":null,"created_at":\(Date().addingTimeInterval(-daysOld * 86_400).timeIntervalSinceReferenceDate),
         "description":null,"skills":"[]","saved":false,"interested_count":0,"poster_id":"u","poster_name":"P",
         "poster_avatar":null,"poster_color":null,"poster_title":null,"followed_company":\(followed),"semantic":\(semantic)}
        """
        return try! JSONDecoder().decode(JobBoardStore.Row.self, from: Data(json.utf8))
    }

    private let me = JobBoardStore.Viewer(
        skills: Set(["Swift", "SwiftUI", "Node.js"].map(JobBoardStore.normalize)),
        titleWords: Set(JobBoardStore.words("iOS Developer")),
        placeWords: Set(JobBoardStore.words("Hồ Chí Minh")))

    func testSkillsMatchIgnoringCaseAndPunctuation() {
        let m = JobBoardStore.match(row(), skills: ["swift", "NodeJS", "Kotlin"], viewer: me)
        XCTAssertEqual(m.matched_skills, ["swift", "NodeJS"])
        XCTAssertEqual(m.missing_skills, ["Kotlin"])
        XCTAssertEqual(m.reason, "skills")
    }

    func testReasonsWhenNoSkillsMatch() {
        XCTAssertEqual(JobBoardStore.match(row(followed: true), skills: ["Kotlin"], viewer: me).reason, "company")
        XCTAssertEqual(JobBoardStore.match(row(), skills: [], viewer: me).reason, "near")     // accents folded
        XCTAssertEqual(JobBoardStore.match(row(location: "Hanoi", format: "remote"), skills: [], viewer: me).reason, "remote")
        XCTAssertEqual(JobBoardStore.match(row(location: "Hanoi", format: "onsite"), skills: [], viewer: me).reason, "title")
        XCTAssertEqual(JobBoardStore.match(row(title: "Accountant", location: "Hanoi", format: "onsite"), skills: [], viewer: me).reason, "profile")
    }

    func testABetterFitScoresHigher() {
        let strong = JobBoardStore.match(row(semantic: 0.8), skills: ["Swift", "SwiftUI"], viewer: me).score
        let weak = JobBoardStore.match(row(title: "Accountant", location: "Hanoi", format: "onsite", semantic: 0.2, daysOld: 60),
                                       skills: ["Excel"], viewer: me).score
        XCTAssertGreaterThan(strong, weak)
        XCTAssertLessThanOrEqual(strong, 1)
    }
}
