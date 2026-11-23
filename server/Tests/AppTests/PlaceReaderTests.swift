@testable import App
import XCTest

final class PlaceReaderTests: XCTestCase {
    /// A small corner of the real data: three of today's wards in Hồ Chí Minh
    /// (79), a Tân An in two provinces, and what some of them used to be.
    static let gazetteer = PlaceReader.Gazetteer(
        wards: [
            .init(id: "SG", name: "Sài Gòn", province_code: "79", province_name: "Thành phố Hồ Chí Minh"),
            .init(id: "BT", name: "Bến Thành", province_code: "79", province_name: "Thành phố Hồ Chí Minh"),
            .init(id: "TD", name: "Tân Định", province_code: "79", province_name: "Thành phố Hồ Chí Minh"),
            .init(id: "DA", name: "Dĩ An", province_code: "79", province_name: "Thành phố Hồ Chí Minh"),
            .init(id: "HK", name: "Hoàn Kiếm", province_code: "01", province_name: "Thành phố Hà Nội"),
            .init(id: "TA1", name: "Tân An", province_code: "80", province_name: "Tỉnh Tây Ninh"),
            .init(id: "TA2", name: "Tân An", province_code: "92", province_name: "Thành phố Cần Thơ"),
            .init(id: "KH", name: "Khánh Hoà", province_code: "92", province_name: "Thành phố Cần Thơ"),
            .init(id: "HB", name: "Hoà Bình", province_code: "25", province_name: "Tỉnh Phú Thọ"),
        ],
        former: [
            f("SG", "79", "Phường Bến Nghé", "Quận 1", "Thành phố Hồ Chí Minh"),
            f("SG", "79", "Phường Đa Kao", "Quận 1", "Thành phố Hồ Chí Minh"),
            f("TD", "79", "Phường Đa Kao", "Quận 1", "Thành phố Hồ Chí Minh"),
            f("TD", "79", "Phường Tân Định", "Quận 1", "Thành phố Hồ Chí Minh"),
            f("BT", "79", "Phường Bến Thành", "Quận 1", "Thành phố Hồ Chí Minh"),
            f("BT", "79", "Phường 1", "Quận 3", "Thành phố Hồ Chí Minh"),
            f("TD", "79", "Phường 1", "Quận 5", "Thành phố Hồ Chí Minh"),
            f("DA", "79", "Phường Dĩ An", "Thành phố Dĩ An", "Tỉnh Bình Dương"),
            f("HK", "01", "Phường Hàng Bạc", "Quận Hoàn Kiếm", "Thành phố Hà Nội"),
            f("TA1", "80", "Phường 1", "Thành phố Tân An", "Tỉnh Long An"),
            f("HB", "25", "Phường Đồng Tiến", "Thành phố Hòa Bình", "Tỉnh Hòa Bình"),
        ])

    static func f(_ ward: String, _ code: String, _ name: String?, _ district: String, _ province: String) -> PlaceReader.FormerRow {
        .init(ward_id: ward, province_code: code, former_name: name, former_district: district, former_province: province)
    }

    private func wards(_ text: String) -> Set<String> { PlaceReader.read(text, in: Self.gazetteer).wardIDs }
    private func provinces(_ text: String) -> Set<String> { PlaceReader.read(text, in: Self.gazetteer).provinceCodes }

    func testTodaysWardName() {
        XCTAssertEqual(wards("Quán ở 12 Lê Lợi, Phường Sài Gòn, TP.HCM"), ["sg"])
        XCTAssertEqual(wards("P. Bến Thành nha mọi người"), ["bt"])
    }

    func testFormerWardReadsAsTodaysWard() {
        XCTAssertEqual(wards("Phường Bến Nghé, Quận 1"), ["sg"])
        XCTAssertEqual(wards("phường Hàng Bạc, Hà Nội"), ["hk"])
    }

    func testSplitFormerWardReadsAsEveryWardItJoined() {
        XCTAssertEqual(wards("Phường Đa Kao, Quận 1, TP.HCM"), ["sg", "td"])
    }

    func testTodaysNameWinsOverFormerWardOfTheSameName() {
        XCTAssertEqual(wards("Phường Tân Định"), ["td"])
    }

    func testDistrictOnItsOwnIsEveryWardFormedFromIt() {
        XCTAssertEqual(wards("quán nướng ở Quận 1"), ["sg", "td", "bt"])
        XCTAssertEqual(wards("Q1"), ["sg", "td", "bt"])
        XCTAssertEqual(wards("Q.3 có quán này ngon"), ["bt"])
    }

    func testDistrictThatPlacesAWardIsNotExpanded() {
        XCTAssertEqual(wards("Phường 1, Quận 3"), ["bt"])
        XCTAssertEqual(wards("P1 Q5"), ["td"])
    }

    func testNameInSeveralPlacesNeedsItsDistrictOrProvince() {
        XCTAssertEqual(wards("Phường 1"), [])
        XCTAssertEqual(wards("Phường 1, TP.HCM"), [])
        XCTAssertEqual(wards("Phường Tân An"), [])
        XCTAssertEqual(wards("Phường Tân An, Cần Thơ"), ["ta2"])
        XCTAssertEqual(wards("Phường 1, Long An"), ["ta1"])
    }

    func testNameWithoutItsKindIsNotAPlace() {
        XCTAssertEqual(wards("Sài Gòn hôm nay mưa, ghé Bến Thành ăn tối"), [])
        XCTAssertEqual(wards("nhà mình ở xa trung tâm"), [])
    }

    func testTonePlacementAndUnaccentedText() {
        XCTAssertEqual(PlaceReader.key("Hòa"), PlaceReader.key("Hoà"))
        XCTAssertNotEqual(PlaceReader.key("Hòa"), PlaceReader.key("Hóa"))
        XCTAssertEqual(wards("Phường Khánh Hòa, Cần Thơ"), ["kh"])
        XCTAssertEqual(wards("phuong ben nghe quan 1"), ["sg"])
        XCTAssertEqual(wards("quan 1"), ["sg", "td", "bt"])
    }

    func testProvinces() {
        XCTAssertEqual(provinces("ở Hà Nội"), ["01"])
        XCTAssertEqual(provinces("TP.HCM"), ["79"])
        XCTAssertEqual(provinces("tphcm"), ["79"])
        XCTAssertEqual(provinces("ha noi"), ["01"])
        // A former province is today's province it became part of.
        XCTAssertEqual(provinces("Bình Dương"), ["79"])
        XCTAssertEqual(wards("Phường Dĩ An, Bình Dương"), ["da"])
    }

    func testEverydayWordsThatAreAlsoProvinces() {
        XCTAssertEqual(provinces("mong thế giới hòa bình"), [])
        XCTAssertEqual(provinces("Tỉnh Hòa Bình"), ["25"])
    }

    func testFormerCityDistrict() {
        XCTAssertEqual(wards("Thành phố Dĩ An"), ["da"])
        XCTAssertEqual(provinces("Thành phố Hồ Chí Minh"), ["79"])
    }

    // MARK: a phrase known to be a place

    private func place(_ phrase: String, home: String? = nil) -> PlaceReader.Places {
        PlaceReader.read(phrase, in: Self.gazetteer, bare: true, homeProvince: home)
    }

    func testNameOnItsOwnCounts() {
        XCTAssertEqual(place("bến nghé").wardIDs, ["sg"])
        XCTAssertEqual(place("ben nghe").wardIDs, ["sg"])
        XCTAssertEqual(place("Bến Nghé, Q1").wardIDs, ["sg"])
    }

    func testNameThatIsADistrictAndAWardMeansTheDistrict() {
        // Hoàn Kiếm is today's ward and the former district it came from.
        XCTAssertEqual(place("hoàn kiếm").wardIDs, ["hk"])
        // Dĩ An: the former city (district level) covers the ward of the same name.
        XCTAssertEqual(place("di an").wardIDs, ["da"])
    }

    func testWardInsideANamedDistrictStaysNarrow() {
        XCTAssertEqual(place("phường 1 quận 3").wardIDs, ["bt"])
    }

    func testNameInSeveralProvincesFallsBackToHome() {
        XCTAssertEqual(place("tân an", home: "92").wardIDs, ["ta2"])
        XCTAssertEqual(place("tân an", home: "80").wardIDs, ["ta1"])
        // No home: the former city Tân An is the only district of that name.
        XCTAssertEqual(place("tân an").wardIDs, ["ta1"])
        // A province in the phrase beats home.
        XCTAssertEqual(place("tân an, cần thơ", home: "80").wardIDs, ["ta2"])
    }

    func testProvinceOnItsOwnIsOnlyAProvince() {
        let p = place("hà nội")
        XCTAssertEqual(p.provinceCodes, ["01"])
        XCTAssertEqual(p.wardIDs, [])
        XCTAssertEqual(place("hue").provinceCodes, [])        // not in this gazetteer
        XCTAssertEqual(place("hòa bình").provinceCodes, ["25"])
    }

    func testStreetAddressIsLeftToTheGeocoder() {
        XCTAssertTrue(place("45 Lê Thánh Tôn").street)
        XCTAssertEqual(place("45 Lê Thánh Tôn").wardIDs, [])
        // A street named like a ward is not that ward.
        let p = place("12 Bến Thành, Hà Nội")
        XCTAssertTrue(p.street)
        XCTAssertEqual(p.wardIDs, [])
        XCTAssertEqual(p.provinceCodes, ["01"])
        XCTAssertTrue(place("đường Tân Định").street)
        XCTAssertFalse(place("bến nghé quận 1").street)
    }

    func testNameOutsideTheNamedProvinceIsDropped() {
        XCTAssertEqual(place("bến nghé, hà nội").wardIDs, [])
        XCTAssertEqual(place("bến nghé, hà nội").provinceCodes, ["01"])
        // Home is only a hint.
        XCTAssertEqual(place("bến nghé", home: "01").wardIDs, ["sg"])
    }

    func testBareNumberIsAHouseNumber() {
        let p = place("1 Trần Phú, Q3")
        XCTAssertTrue(p.street)
        XCTAssertEqual(p.wardIDs, ["bt"])   // only what Quận 3 gives
    }

    func testPlacePhraseAfterAPlaceWord() {
        XCTAssertEqual(PlaceReader.placePhrase(in: "tìm bạn ở thủ đức thích cà phê"), "thủ đức thích cà phê")
        XCTAssertEqual(PlaceReader.placePhrase(in: "ban nu gan 45 le thanh ton"), "45 le thanh ton")
        XCTAssertNil(PlaceReader.placePhrase(in: "bạn nữ thích cà phê"))
        XCTAssertEqual(place("bến nghé thích cà phê sữa").wardIDs, ["sg"])
    }

    func testLabelsShowHowThePlaceWasUnderstood() {
        XCTAssertEqual(place("ben nghe").labels, ["Phường Bến Nghé, Quận 1"])
        XCTAssertEqual(place("q1").labels, ["Quận 1"])
        XCTAssertEqual(place("phường sài gòn").labels, ["Sài Gòn"])
        XCTAssertEqual(place("ha noi").labels, ["Thành phố Hà Nội"])
        XCTAssertEqual(place("phường 1").labels, [])
    }

    func testHalfAccentedNameStillReads() {
        XCTAssertEqual(place("bên nghe").wardIDs, ["sg"])
        XCTAssertEqual(place("Hoan Kiếm").wardIDs, ["hk"])
    }

    func testAddressIsCutOutOfThePhrase() {
        XCTAssertEqual(place("45 lê thánh tôn nhé").streetText, "45 lê thánh tôn")
        XCTAssertEqual(place("12 nguyễn trãi quận 3").streetText, "12 nguyễn trãi")
        XCTAssertEqual(place("12 nguyễn trãi quận 3").wardIDs, ["bt"])
        XCTAssertEqual(place("đường Tân Định thích cà phê").streetText, "đường Tân Định")
        XCTAssertNil(place("bến nghé").streetText)
    }

    func testSaiGonOnItsOwnIsTheCity() {
        XCTAssertEqual(place("sài gòn").provinceCodes, ["79"])
        XCTAssertEqual(place("sài gòn").wardIDs, [])
        XCTAssertEqual(place("Saigon").provinceCodes, ["79"])
        XCTAssertEqual(place("phường sài gòn").wardIDs, ["sg"])
        XCTAssertEqual(place("bến nghé, sài gòn").wardIDs, ["sg"])
    }

    func testWardOutsideHomeIsDroppedForAPost() {
        func post(_ phrase: String, home: String?) -> Set<String> {
            PlaceReader.read(phrase, in: Self.gazetteer, bare: true, homeProvince: home, strictHome: true).wardIDs
        }
        XCTAssertEqual(post("bến nghé", home: "79"), ["sg"])
        XCTAssertEqual(post("bến nghé", home: "01"), [])
        XCTAssertEqual(post("bến nghé, sài gòn", home: "01"), ["sg"])   // the province it names wins
        XCTAssertEqual(post("hoàn kiếm", home: "79"), ["hk"])           // a district stands on its own
    }

    func testEnglishKinds() {
        XCTAssertEqual(place("District 3").wardIDs, ["bt"])
        XCTAssertEqual(place("Ward 1, District 5").wardIDs, ["td"])
    }

    func testVietnameseUnitNamesInEnglish() {
        XCTAssertEqual(PlaceReader.english("Phường Bến Nghé, Quận 1"), "Ben Nghe Ward, District 1")
        XCTAssertEqual(PlaceReader.english("Phường 12, Quận Gò Vấp"), "Ward 12, Go Vap District")
        XCTAssertEqual(PlaceReader.english("Thị trấn Tân Khai, Huyện Hớn Quản"), "Tan Khai Township, Hon Quan District")
        XCTAssertEqual(PlaceReader.english("Thành phố Thủ Đức"), "Thu Duc City")
        XCTAssertEqual(PlaceReader.english("Tỉnh Bình Dương"), "Binh Duong Province")
        XCTAssertEqual(PlaceReader.english("Xã Đồng Nơ"), "Dong No Commune")
        XCTAssertEqual(PlaceReader.english("Huyện Côn Đảo"), "Con Dao District")
        XCTAssertEqual(PlaceReader.english("Sài Gòn"), "Sai Gon")
    }

    func testWholeTextStillNeedsTheKind() {
        XCTAssertEqual(wards("ghé Bến Nghé ăn tối"), [])
    }

    /// The public geocoder answered "landmark 81" with "PetroVietnam
    /// Landmark", an apartment block in another ward.
    func testAGeocoderAnswerMustCarryTheNumbersOfTheName() {
        let petro: [String: Any] = ["name": "PetroVietnam Landmark", "address": ["suburb": "Phường Bình Trưng"]]
        let tower: [String: Any] = ["name": "Vincom Landmark 81", "address": [:] as [String: Any]]
        let house: [String: Any] = ["name": "", "address": ["house_number": "45", "road": "Lê Thánh Tôn"]]
        XCTAssertFalse(VenueLocationService.namesTheSame(petro, as: "landmark 81, Thành phố Hồ Chí Minh"))
        XCTAssertTrue(VenueLocationService.namesTheSame(tower, as: "landmark 81, Thành phố Hồ Chí Minh"))
        XCTAssertTrue(VenueLocationService.namesTheSame(house, as: "45 lê thánh tôn"))
        XCTAssertTrue(VenueLocationService.namesTheSame(petro, as: "hồ tây, Thành phố Hà Nội"))
    }
}
