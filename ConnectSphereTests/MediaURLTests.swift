import Foundation
import Testing
@testable import ConnectSphere

struct MediaURLTests {
    @Test func storedPathGetsThisDevicesServer() {
        #expect(APIConfig.mediaURL("/uploads/a.jpg")?.absoluteString == APIConfig.serverBase + "/uploads/a.jpg")
    }

    @Test func outsideLinksAreUsedAsTheyAre() {
        let thumb = "https://i.ytimg.com/vi/x/hqdefault.jpg"
        #expect(APIConfig.mediaURL(thumb)?.absoluteString == thumb)
    }

    @Test func blankIsNoURL() {
        #expect(APIConfig.mediaURL(nil) == nil)
        #expect(APIConfig.mediaURL("  ") == nil)
    }
}
