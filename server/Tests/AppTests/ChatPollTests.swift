@testable import App
import Vapor
import XCTest

final class ChatPollTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAValidPollIsTrimmed() throws {
        let poll = try ChatStore.validatePoll(question: "  Where should we eat? ", options: [" Phở ", "Bún bò", "  "],
                                              endsAt: "2027-01-15T12:00:00Z", now: now)
        XCTAssertEqual(poll.question, "Where should we eat?")
        XCTAssertEqual(poll.options, ["Phở", "Bún bò"])   // blank options dropped
        XCTAssertNotNil(poll.endsAt)
    }

    func testRejectsBadPolls() {
        func rejects(_ question: String?, _ options: [String]?, _ endsAt: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try ChatStore.validatePoll(question: question, options: options, endsAt: endsAt, now: now),
                                 file: file, line: line)
        }
        rejects(nil, ["a", "b"])
        rejects("   ", ["a", "b"])
        rejects(String(repeating: "q", count: 201), ["a", "b"])
        rejects("Q", ["only one"])
        rejects("Q", (1...7).map { "option \($0)" })
        rejects("Q", ["a", String(repeating: "x", count: 81)])
        rejects("Q", ["Same", "same"])                     // duplicates, ignoring case
        rejects("Q", ["a", "b"], "2020-01-01T00:00:00Z")   // ends in the past
        rejects("Q", ["a", "b"], "not a date")
    }

    func testLimitsAreInclusive() throws {
        XCTAssertNoThrow(try ChatStore.validatePoll(question: String(repeating: "q", count: 200),
                                                    options: (1...6).map { String(repeating: "\($0)", count: 80) },
                                                    endsAt: nil, now: now))
    }
}
