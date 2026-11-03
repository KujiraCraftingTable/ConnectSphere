@testable import App
import XCTest

/// Dating (migration 081) is 16+ only, and 16–17 never meets 18+.
final class DatingRulesTests: XCTestCase {
    private func person(age: Int?, gender: String = "female", wants: String = "everyone",
                        ages: ClosedRange<Int> = 16...99, maxKm: Int? = nil,
                        at place: (Double, Double) = (21.03, 105.85)) -> DatingRules.Person {
        .init(age: age, gender: gender, interestedIn: wants, minAge: ages.lowerBound, maxAge: ages.upperBound,
              maxDistanceKm: maxKm, latitude: place.0, longitude: place.1)
    }

    // MARK: age gate

    func testUnder16AndUnknownAgeAreLocked() {
        XCTAssertNil(DatingRules.band(age: nil))
        XCTAssertNil(DatingRules.band(age: 15))
        XCTAssertNil(DatingRules.band(age: 0))
        XCTAssertEqual(DatingRules.band(age: 16), .teen)
        XCTAssertEqual(DatingRules.band(age: 17), .teen)
        XCTAssertEqual(DatingRules.band(age: 18), .adult)
    }

    func testMinimumAgeIsTheOneSearchUses() {
        XCTAssertEqual(DatingRules.minAge, SearchController.datingMinAge)
    }

    func testTeensAndAdultsNeverMeetWhateverTheirRange() {
        XCTAssertFalse(DatingRules.isFit(person(age: 17), person(age: 18)))
        XCTAssertFalse(DatingRules.isFit(person(age: 30), person(age: 16)))
        XCTAssertTrue(DatingRules.isFit(person(age: 16), person(age: 17)))
        XCTAssertTrue(DatingRules.isFit(person(age: 18), person(age: 40)))
    }

    func testLockedPeopleAreNeverAFit() {
        XCTAssertFalse(DatingRules.isFit(person(age: 15), person(age: 16)))
        XCTAssertFalse(DatingRules.isFit(person(age: nil), person(age: 20)))
    }

    func testTheBandClampsTheChosenRange() {
        XCTAssertEqual(DatingRules.effectiveRange(band: .teen, min: 16, max: 40), 16...17)
        XCTAssertEqual(DatingRules.effectiveRange(band: .adult, min: 16, max: 25), 18...25)
        XCTAssertNil(DatingRules.effectiveRange(band: .teen, min: 20, max: 30))
        XCTAssertNil(DatingRules.effectiveRange(band: .adult, min: 16, max: 17))
    }

    // MARK: who meets whom

    func testInterestMustHoldBothWays() {
        let man = person(age: 22, gender: "male", wants: "women")
        let woman = person(age: 23, gender: "female", wants: "men")
        let womanForWomen = person(age: 23, gender: "female", wants: "women")
        XCTAssertTrue(DatingRules.isFit(man, woman))
        XCTAssertTrue(DatingRules.isFit(woman, man))
        XCTAssertFalse(DatingRules.isFit(man, womanForWomen))
    }

    func testOtherGenderOnlyShowsToEveryone() {
        let other = person(age: 25, gender: "other")
        XCTAssertFalse(DatingRules.isFit(person(age: 25, wants: "men"), other))
        XCTAssertFalse(DatingRules.isFit(person(age: 25, wants: "women"), other))
        XCTAssertTrue(DatingRules.isFit(person(age: 25, wants: "everyone"), other))
    }

    func testAgeRangeMustHoldBothWays() {
        let picky = person(age: 30, ages: 28...35)
        XCTAssertTrue(DatingRules.isFit(picky, person(age: 29)))
        XCTAssertFalse(DatingRules.isFit(picky, person(age: 25)))
        XCTAssertFalse(DatingRules.isFit(person(age: 29, ages: 18...25), picky))
    }

    func testBothDistanceLimitsApply() {
        let hanoi = (21.03, 105.85), saigon = (10.78, 106.70)
        let km = DatingRules.distanceKm(hanoi.0, hanoi.1, saigon.0, saigon.1)
        XCTAssertEqual(km, 1140, accuracy: 15)
        XCTAssertTrue(DatingRules.isFit(person(age: 20, at: hanoi), person(age: 20, at: saigon)))
        XCTAssertFalse(DatingRules.isFit(person(age: 20, maxKm: 50, at: hanoi), person(age: 20, at: saigon)))
        XCTAssertFalse(DatingRules.isFit(person(age: 20, at: hanoi), person(age: 20, maxKm: 50, at: saigon)))
        XCTAssertTrue(DatingRules.isFit(person(age: 20, maxKm: 5, at: hanoi), person(age: 20, maxKm: 5, at: (21.04, 105.86))))
    }

    // MARK: matching

    func testOnlyALikeBackMakesAMatch() {
        XCTAssertTrue(DatingRules.makesMatch(liked: true, theyLikedMe: true))
        XCTAssertFalse(DatingRules.makesMatch(liked: true, theyLikedMe: false))
        XCTAssertFalse(DatingRules.makesMatch(liked: false, theyLikedMe: true))
        XCTAssertFalse(DatingRules.makesMatch(liked: false, theyLikedMe: false))
    }

    func testAPairIsStoredOnceWhoeverLikesLast() {
        let x = "B154ECEE-0B76-4D01-B947-9904B0689585", y = "0a1b2c3d-0000-4000-8000-000000000000"
        let first = DatingRules.pair(x, y), second = DatingRules.pair(y, x)
        XCTAssertEqual(first.a, second.a)
        XCTAssertEqual(first.b, second.b)
        XCTAssertEqual(first.a, y)
        XCTAssertLessThan(first.a, first.b)
    }

    // MARK: profile

    private func profile(_ edit: (inout DatingRules.ProfileInput) -> Void = { _ in }) -> DatingRules.ProfileInput {
        var p = DatingRules.ProfileInput(bio: "Hi", interestedIn: "women", minAge: 18, maxAge: 30, maxDistanceKm: 20,
                                         heightCm: 175, hasKids: nil, city: "Hà Nội", latitude: 21.03, longitude: 105.85,
                                         photos: ["/uploads/a.jpg"])
        edit(&p)
        return p
    }

    func testAValidProfileSaves() {
        XCTAssertNil(DatingRules.problem(with: profile()))
        XCTAssertNil(DatingRules.problem(with: profile { $0.heightCm = nil; $0.maxDistanceKm = nil }))
    }

    func testProfileLimits() {
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.interestedIn = "robots" }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.minAge = 15 }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.minAge = 31 }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.maxDistanceKm = 0 }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.heightCm = 300 }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.bio = String(repeating: "a", count: 501) }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.city = "" }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.latitude = 91 }))
    }

    func testOneToSixUploadedPhotos() {
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.photos = [] }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.photos = Array(repeating: "/uploads/a.jpg", count: 7) }))
        XCTAssertNil(DatingRules.problem(with: profile { $0.photos = Array(repeating: "/uploads/a.jpg", count: 6) }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.photos = ["https://example.com/a.jpg"] }))
    }

    func testKidsAnswerIsOptionalButFromTheList() {
        XCTAssertNil(DatingRules.problem(with: profile { $0.hasKids = "prefer_not" }))
        XCTAssertNil(DatingRules.problem(with: profile { $0.hasKids = nil }))
        XCTAssertNotNil(DatingRules.problem(with: profile { $0.hasKids = "maybe" }))
    }

    func testALocationNeedsAPlaceNameAndRealCoordinates() {
        XCTAssertNil(DatingRules.locationProblem(city: "Quận 1, Hồ Chí Minh", latitude: 10.77, longitude: 106.70))
        XCTAssertNotNil(DatingRules.locationProblem(city: "", latitude: 10.77, longitude: 106.70))
        XCTAssertNotNil(DatingRules.locationProblem(city: "Quận 1", latitude: 10.77, longitude: 200))
    }
}
