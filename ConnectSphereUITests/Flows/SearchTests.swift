import XCTest

/// P2: people search, AI and keyword. Fixture people are this run's accounts
/// with a made-up bio and interests, embedded through the test hook.
final class SearchTests: UITestCase {
    private var search: SearchScreen { SearchScreen(app: app) }

    private func launchToSearch(as account: TestServer.Account) throws {
        launch(signedInAs: account)
        try FeedScreen(app: app).waitUntilLoaded()
        try search.open()
    }

    func testAISearchFindsFixturePeople() async throws {
        let fixtures = try await server.createAccounts(
            run: run, count: 2,
            bio: "Urban beekeeper who builds wooden hives and sells raw honey at weekend markets.",
            interests: ["Beekeeping", "Woodworking"])
        let me = try await server.createAccount(run: run)
        let built = try await server.embedRun(run)
        XCTAssertGreaterThanOrEqual(built, fixtures.count)

        try launchToSearch(as: me)
        try search.setAI(true)
        // Worded as interests: the query parser reads these as two interest groups.
        try search.search("friends who love woodworking and beekeeping")
        for person in fixtures {
            try search.row(person.id).waitToAppear(timeout: 90)
        }
        try search.aiLoading.waitToDisappear(timeout: 30)
    }

    func testWorkShowsCompaniesScope() async throws {
        let me = try await server.createAccount(run: run)
        try launchToSearch(as: me)
        try search.scope("People").waitToAppear()
        XCTAssertFalse(search.scope("Companies").exists, "Hobby search has no Companies scope")

        let feed = FeedScreen(app: app)
        try MainScreen(app: app).tab(AXID.Tab.home).tapWhenReady()
        try feed.mode("work").tapWhenReady()
        try feed.mode("work").waitUntilSelected(true)
        try search.open()
        try search.scope("Companies").waitToAppear(timeout: 15)
    }

    func testKeywordSearchFindsByName() async throws {
        let others = try await server.createAccounts(run: run, count: 2)
        let me = others[0], target = others[1]
        try launchToSearch(as: me)
        XCTAssertFalse(search.aiToggle.isSelected, "AI search starts off")
        try search.search(target.username)
        try search.row(target.id).waitToAppear(timeout: 20)
        XCTAssertFalse(search.aiLoading.exists)
    }

    func testUnmatchedQueryShowsNoResults() async throws {
        let me = try await server.createAccount(run: run)
        try launchToSearch(as: me)
        try search.search("zqxv\(run)")
        try search.noResults.waitToAppear(timeout: 20)
        XCTAssertEqual(app.descendants(matching: .any).withIDPrefix(AXID.Search.row).count, 0)
    }
}
