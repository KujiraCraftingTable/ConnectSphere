import Foundation
import Testing
@testable import ConnectSphere

/// What the server's content checks say, as the app reads it (migration 089).
struct ModerationMessageTests {
    @Test func recognisesTheAskFirstReply() {
        #expect(ModerationMessage.isConfirmRequired(APIError.serverError(statusCode: 422, message: "confirm_required")))
        #expect(ModerationMessage.isConfirmRequired(WebSocketError.serverError("confirm_required")))
        #expect(!ModerationMessage.isConfirmRequired(APIError.serverError(statusCode: 422, message: "something else")))
        #expect(!ModerationMessage.isConfirmRequired(URLError(.timedOut)))
    }

    @Test func refusalsAreShownInTheAppsLanguage() {
        let text = ModerationMessage.localized("This goes against our rules on child safety.")
        #expect(text?.contains("child") == true || text?.contains("trẻ em") == true)
        #expect(ModerationMessage.localized("This goes against our rules on made_up.") == nil)
        #expect(ModerationMessage.localized("Not found") == nil)
        #expect(ModerationMessage.localized("Please choose a name without offensive words.") != nil)
    }
}
