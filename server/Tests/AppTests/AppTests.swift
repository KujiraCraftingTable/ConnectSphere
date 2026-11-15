import XCTVapor
@testable import App

final class AppTests: XCTestCase {
    func testEnvLoadDefaults() throws {
        let env = try AppEnv.load { key in
            [
                "DB_HOST": "localhost", "DB_PORT": "5432", "DB_NAME": "connectsphere",
                "DB_USER": "connectsphere_user", "DB_PASSWORD": "connectsphere_pass",
            ][key]
        }
        XCTAssertEqual(env.port, 3000)
        XCTAssertEqual(env.jwt.expiresIn, "90d")
        XCTAssertEqual(env.ollama.model, "qwen2.5:7b-instruct-q4_k_m")
        XCTAssertEqual(env.db.poolMax, 10)
        XCTAssertFalse(env.isProduction)
    }

    func testEnvMissingRequiredThrows() {
        XCTAssertThrowsError(try AppEnv.load { _ in nil })
    }

    func testEnvWeakJWTRejectedInProduction() {
        XCTAssertThrowsError(try AppEnv.load { key in
            [
                "DB_HOST": "h", "DB_PORT": "5432", "DB_NAME": "d", "DB_USER": "u", "DB_PASSWORD": "p",
                "NODE_ENV": "production", "JWT_SECRET": "dev_secret",
            ][key]
        })
    }

    // MARK: JWTHS256, the token format must not change.

    func testJWTDurationParsing() {
        XCTAssertEqual(JWTHS256.seconds(from: "90d"), 90 * 86400)
        XCTAssertEqual(JWTHS256.seconds(from: "1h"), 3600)
        XCTAssertEqual(JWTHS256.seconds(from: "3600"), 3600)
        XCTAssertEqual(JWTHS256.seconds(from: "30m"), 1800)
        XCTAssertEqual(JWTHS256.seconds(from: "junk"), 90 * 86400)
    }

    func testJWTRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = JWTHS256.sign(sub: "abc-123", secret: "s3cr3t", expiresIn: "90d", now: now)
        let parts = token.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        // header is the canonical JWT header
        XCTAssertEqual(JWTHS256.b64Decode(String(parts[0])).flatMap { String(data: $0, encoding: .utf8) },
                       #"{"alg":"HS256","typ":"JWT"}"#)
        let payload = try JWTHS256.verify(token, secret: "s3cr3t", now: now.addingTimeInterval(60))
        XCTAssertEqual(payload.sub, "abc-123")
        XCTAssertEqual(payload.iat, 1_700_000_000)
        XCTAssertEqual(payload.exp, 1_700_000_000 + 90 * 86400)
    }

    func testJWTRejectsTamperAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let token = JWTHS256.sign(sub: "u", secret: "right", expiresIn: "1h", now: now)
        XCTAssertThrowsError(try JWTHS256.verify(token, secret: "wrong", now: now))
        XCTAssertThrowsError(try JWTHS256.verify(token, secret: "right", now: now.addingTimeInterval(7200)))
    }

    func testSearchTokenizerSplitsAndKeepsDiacritics() {
        // Accent folding happens in SQL (unaccent), so the words keep theirs.
        XCTAssertEqual(SearchTokenizer.words("Mèo méo meo!"), ["mèo", "méo", "meo"])
        XCTAssertEqual(SearchTokenizer.words("anime,manga / JJK"), ["anime", "manga", "jjk"])
    }

    func testSearchTokenizerDropsNoiseAndCaps() {
        XCTAssertEqual(SearchTokenizer.words("a I anime anime"), ["anime"], "1-char tokens and duplicates")
        XCTAssertEqual(SearchTokenizer.words("%_\\'; -- !!"), [], "no letters or digits → no words")
        let many = (1...12).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(SearchTokenizer.words(many).count, SearchTokenizer.maxWords)
    }

    func testSearchTokenizerCannotCarryWildcards() {
        for w in SearchTokenizer.words("50%_off c_a%t a\\b") {
            XCTAssertTrue(w.allSatisfy { $0.isLetter || $0.isNumber }, w)
        }
    }

    /// Voice notes (.m4a) and iPhone photos (.heic) were rejected after the
    /// Node→Swift port because the whitelist matched Vapor's extension-derived
    /// MIME, which maps m4a to audio/mpeg.
    func testChatAttachmentWhitelist() {
        let kind = MessagesController.attachmentType(forFilename:)
        XCTAssertEqual(kind("upload.m4a")?.messageType, "voice")
        XCTAssertEqual(kind("upload.m4a")?.ext, ".m4a")
        XCTAssertEqual(kind("IMG_0001.HEIC")?.messageType, "image")
        XCTAssertEqual(kind("upload.jpeg")?.ext, ".jpg")
        XCTAssertEqual(kind("clip.mov")?.messageType, "video")
        for rejected in ["evil.exe", "x.svg", "page.html", "noextension", "archive.m4a.zip"] {
            XCTAssertNil(kind(rejected), rejected)
        }
    }

    // MARK: PostRanking: criteria met, then popularity, then closeness.

    func testPostMeetingMoreOfThePromptComesFirst() {
        let both = PostRanking.Key(criteria: 2, engagement: 0, match: 0.61)
        let one = PostRanking.Key(criteria: 1, engagement: 5_000, match: 0.9)
        XCTAssertTrue(PostRanking.comesFirst(both, one))
        XCTAssertFalse(PostRanking.comesFirst(one, both))
    }

    func testAmongEqualsTheMostPopularComesFirst() {
        let popular = PostRanking.Key(criteria: 1, engagement: 30, match: 0.62)
        let closer = PostRanking.Key(criteria: 1, engagement: 2, match: 0.80)
        XCTAssertTrue(PostRanking.comesFirst(popular, closer))
        let tie = PostRanking.Key(criteria: 1, engagement: 2, match: 0.70)
        XCTAssertTrue(PostRanking.comesFirst(closer, tie))
    }

    func testEngagementCountsLikesSharesAndCommentsAlike() {
        XCTAssertEqual(PostRanking.engagement(likes: 3, shares: 2, comments: 1), 6)
        XCTAssertEqual(PostRanking.engagement(likes: -5, shares: 0, comments: 4), 4)
    }

    // MARK: People search. Reactions as evidence, never revealing likes.

    private func rawUser(evidence: String) -> SearchStore.RawUser {
        SearchStore.RawUser(
            id: "u1", username: "lurker", display_name: nil, bio: nil, avatar_url: nil, cover_url: nil,
            avatar_color: nil, location: nil, job_title: nil, company: nil, default_mode: "hobby",
            gender: nil, age: nil, follower_count: 0, following_count: 0, post_count: 0,
            interests: "[]", skills: "[]", score: 0.6, retrieval: 0.6, name_match: 0,
            match_evidence: evidence, mutual_count: 0)
    }

    func testEngagementEvidenceMapsToItsOwnType() {
        let raw = #"[{"source_type":"engagement","topic":"rock climbing","content":"Climbing granite in Yosemite","similarity":0.68,"commented_count":2,"shared_count":0}]"#
        let out = SearchController.finalize([rawUser(evidence: raw)], terms: ["climbing"], communityByUser: [:])
        let ev = out[0].match_evidence[0]
        XCTAssertEqual(ev.type, "engagement")
        XCTAssertEqual(ev.commented_count, 2)
        XCTAssertEqual(ev.shared_count, 0)
        XCTAssertEqual(ev.matched_terms, ["climbing"])
    }

    func testSearchResultJSONNeverCarriesLikesOrReactedPostText() throws {
        // A like-only reactor: counts are 0 and nothing names a like or the post.
        let raw = #"[{"source_type":"engagement","topic":"rock climbing","content":"Secret liked post text","similarity":0.6,"commented_count":0,"shared_count":0}]"#
        let out = SearchController.finalize([rawUser(evidence: raw)], terms: [], communityByUser: [:])
        let json = String(data: try JSONEncoder().encode(out), encoding: .utf8)!.lowercased()
        XCTAssertFalse(json.contains("like"))
        XCTAssertFalse(json.contains("secret liked post text"))
    }

    func testEngagementAndAuthoredEvidenceStaySeparate() {
        let authored = SearchStore.RawEvidence(source_type: "post", topic: "hiking", similarity: 0.7)
        let reacted = SearchStore.RawEvidence(source_type: "engagement", topic: "hiking", similarity: 0.6)
        XCTAssertNotEqual(SearchController.evidenceKey(authored), SearchController.evidenceKey(reacted))
        XCTAssertEqual(SearchController.mergeEvidence([authored], [reacted]).count, 2)
    }

    func testOneReactionScoresBelowAuthoringTheSameMatch() {
        XCTAssertLessThan(SearchStore.wReactLike, SearchStore.wReactCommentOrShare)
        XCTAssertLessThan(SearchStore.wReactCommentOrShare, 1)
    }
}
