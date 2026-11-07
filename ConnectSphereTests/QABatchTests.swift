import Foundation
import Testing
@testable import ConnectSphere

/// Fixes from the 2026-11-06 functional test report that have testable logic.
@MainActor
struct QABatchTests {
    private var vi: Bundle { Bundle(path: Bundle.main.path(forResource: "vi", ofType: "lproj")!)! }
    private var en: Bundle { Bundle(path: Bundle.main.path(forResource: "en", ofType: "lproj")!)! }

    // MARK: Server reasons in Vietnamese

    @Test func serverReasonsAreTranslatedWhenTheAppHasAnEntry() {
        #expect(ServerMessage.localized("Add and verify an email first", in: vi) == "Hãy thêm và xác minh email trước")
        #expect(ServerMessage.localized("Cannot message this user", in: vi) == "Không thể nhắn tin cho người này")
        #expect(ServerMessage.localized("Add and verify an email first", in: en) == "Add and verify an email first")
    }

    @Test func numberedReasonsKeepTheirNumber() {
        #expect(ServerMessage.localized("Wait 42s before asking for a new code", in: vi) == "Hãy chờ 42 giây rồi yêu cầu mã mới")
        #expect(ServerMessage.localized("That code isn't right, 1 try left", in: vi) == "Mã chưa đúng, còn 1 lần thử")
        #expect(ServerMessage.localized("That code isn't right, 3 tries left", in: vi) == "Mã chưa đúng, còn 3 lần thử")
        #expect(ServerMessage.localized("Wait 42s before asking for a new code", in: en) == "Wait 42s before asking for a new code")
    }

    @Test func unknownReasonsComeBackUnchanged() {
        #expect(ServerMessage.localized("Something the server invented", in: vi) == "Something the server invented")
    }

    @Test func englishAndVietnameseStringsHaveTheSameKeys() throws {
        func keys(_ bundle: Bundle) throws -> Set<String> {
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let dict = try #require(NSDictionary(contentsOf: url) as? [String: String])
            return Set(dict.keys)
        }
        #expect(try keys(en).symmetricDifference(keys(vi)).isEmpty)
    }

    // MARK: Interest names

    private func catalog() throws -> InterestCatalog {
        let json = """
        {"max_picks":10,"categories":[{"key":"games","name_en":"Gaming","name_vi":"Trò chơi","section":"main",
          "entries":[{"name_en":"Gaming","name_vi":"Trò chơi","aliases":[],"allows_specific":true,"pick_count":3},
                     {"name_en":"Movies","name_vi":"Phim ảnh","aliases":[],"allows_specific":false,"pick_count":9}]}]}
        """
        return try JSONDecoder().decode(InterestCatalog.self, from: Data(json.utf8))
    }

    @Test func interestsShowInVietnameseOnlyUnderVietnamese() throws {
        let table = InterestNames.table(from: try catalog())
        #expect(InterestNames.display("Movies", vietnamese: true, table: table) == "Phim ảnh")
        #expect(InterestNames.display("movies", vietnamese: true, table: table) == "Phim ảnh")
        #expect(InterestNames.display("Movies", vietnamese: false, table: table) == "Movies")
    }

    @Test func aSpecificPickTranslatesOnlyItsCategory() throws {
        let table = InterestNames.table(from: try catalog())
        #expect(InterestNames.display("Gaming · Roblox", vietnamese: true, table: table) == "Trò chơi · Roblox")
        #expect(InterestNames.display("Unlisted", vietnamese: true, table: table) == "Unlisted")
        #expect(InterestNames.isVietnamese(vi) && !InterestNames.isVietnamese(en))
    }

    @Test func suggestionReasonUsesTheTranslatedInterest() {
        let text = PeopleSuggestionText.reason(.interest("Movies"), mode: .hobby, bundle: vi,
                                               interestName: { _ in "Phim ảnh" })
        #expect(text == "Cũng thích Phim ảnh")
    }

    // MARK: Server address override

    @Test func anOverrideWinsEvenOnTheSimulator() {
        #expect(APIConfig.resolveServerBase(override: "http://localhost:3001", plistValue: "http://mac.local:3000", isSimulator: true)
                == "http://localhost:3001")
        #expect(APIConfig.resolveServerBase(override: " http://x:1 ", plistValue: nil, isSimulator: false) == "http://x:1")
    }

    @Test func withoutAnOverrideTheSimulatorUsesLocalhost() {
        #expect(APIConfig.resolveServerBase(override: "", plistValue: "http://mac.local:3000", isSimulator: true)
                == "http://localhost:3000")
        #expect(APIConfig.resolveServerBase(override: nil, plistValue: "http://mac.local:3000", isSimulator: false)
                == "http://mac.local:3000")
        #expect(APIConfig.resolveServerBase(override: nil, plistValue: "", isSimulator: false) == "http://localhost:3000")
    }

    // MARK: Cancel asks when there is input

    @Test func createCommunityAsksOnceAnythingChanged() {
        let vm = CreateCommunityViewModel(defaultEmoji: "🃏")
        #expect(!vm.hasChanges)
        vm.privacy = .private
        #expect(vm.hasChanges)
        vm.privacy = .public
        vm.selectedEmoji = "🎮"
        #expect(vm.hasChanges)
        vm.selectedEmoji = "🃏"
        vm.selectedColor = "#112233"
        #expect(vm.hasChanges)
        vm.selectedColor = CreateCommunityViewModel.defaultColor
        vm.type = .work
        #expect(vm.hasChanges)
        vm.type = .fandom
        vm.name = "  "
        #expect(!vm.hasChanges)
        vm.name = "Pokemon"
        #expect(vm.hasChanges)
    }

    @Test func emailFormAsksOnlyWhenSomethingIsTyped() {
        let adding = EmailVerificationViewModel(replacingVerifiedEmail: false)
        #expect(!adding.hasChanges)
        adding.email = "a@b.co"
        #expect(adding.hasChanges)

        let overview = EmailVerificationViewModel(replacingVerifiedEmail: true)
        overview.email = "stale@b.co"
        #expect(!overview.hasChanges)   // read-only step: Done just closes
        overview.startChange()
        overview.currentCode = "123"
        #expect(overview.hasChanges)
    }

    // MARK: Community post bar

    private func community(isMember: Bool) throws -> Community {
        let json = """
        {"id":"c1","name":"Pokemon TCG VN","type":"fandom","privacy":"public","icon_emoji":"🃏","cover_color":"#7F5AF0",
         "member_count":12,"post_count":3,"created_at":"2026-10-01T10:00:00.000Z","is_member":\(isMember)}
        """
        return try JSONDecoder.makeISO8601().decode(CommunityDTO.self, from: Data(json.utf8)).toCommunity()
    }

    @Test func onlyNonMembersWhoHaventAskedSeeJoinToPost() throws {
        let vm = CommunityDetailViewModel(communityId: "c1", token: "t", currentUserId: "u1")
        #expect(!vm.showsJoinToPost)                       // nothing loaded yet
        vm.community = try community(isMember: false)
        #expect(vm.showsJoinToPost)
        vm.joinStatus = .pending
        #expect(!vm.showsJoinToPost)                       // pending sees nothing
        vm.joinStatus = .loading
        #expect(!vm.showsJoinToPost)
        vm.community = try community(isMember: true)
        vm.joinStatus = .joined
        #expect(!vm.showsJoinToPost)
    }
}
