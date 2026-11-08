@testable import App
import XCTest

/// Photo checks (migration 090): what a verdict means, and the helpers around it.
final class MediaScanTests: XCTestCase {
    private func result(_ flagged: Bool, _ cats: [String]) -> OpenAIModeration.Result {
        .init(flagged: flagged, categories: cats, scores: [:])
    }

    func testAPhotoIsCleanUnlessFlagged() {
        XCTAssertEqual(MediaScan.decide(result(false, [])).status, .clean)
        XCTAssertNil(MediaScan.decide(result(false, ["sexual"])).policy)   // not flagged: scores only
    }

    func testFlaggedPhotosTakeTheMostSevereRule() {
        let v = MediaScan.decide(result(true, ["violence/graphic", "sexual"]))
        XCTAssertEqual(v.status, .flagged)
        XCTAssertEqual(v.policy?.severity, 1)   // sexual and graphic violence are equally severe
        XCTAssertEqual(MediaScan.decide(result(true, ["self-harm"])).policy, .selfHarm)
    }

    func testAFlagAboutSomethingWeHaveNoRuleForIsClean() {
        XCTAssertEqual(MediaScan.decide(result(true, ["something-new"])).status, .clean)
    }

    func testOnlyFormatsOpenAIReadsAreScanned() {
        XCTAssertEqual(MediaScan.mime(forPath: "/uploads/a.JPG"), "image/jpeg")
        XCTAssertEqual(MediaScan.mime(forPath: "/uploads/a.png"), "image/png")
        XCTAssertEqual(MediaScan.mime(forPath: "/uploads/a.webp"), "image/webp")
        XCTAssertNil(MediaScan.mime(forPath: "/uploads/a.heic"))
        XCTAssertNil(MediaScan.mime(forPath: "/uploads/a.mp4"))
    }

    func testHashesAreSha256() {
        XCTAssertEqual(MediaScan.sha256Hex(Array("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testUploadPathsAreFoundInASnapshot() {
        let snapshot = #"{"content":"x","image_urls":["/uploads/aaa.jpg","/uploads/bbb.png"],"avatar_url":"https://x.test/uploads/c.jpg"}"#
        XCTAssertEqual(MediaScan.uploadPaths(in: snapshot), ["/uploads/aaa.jpg", "/uploads/bbb.png"])
        XCTAssertEqual(MediaScan.uploadPaths(in: "{}"), [])
    }
}
