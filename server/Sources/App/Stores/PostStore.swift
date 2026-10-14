import Vapor
import SQLKit

/// Raw-SQL data access for posts — port of `backend/src/models/postModel.js`.
/// The JSON sub-objects (`author`, `shared_post`, `event_data`, `poll_data`,
/// `tags`) are selected as `::text` and parsed with `JSONCoding.makeDecoder()`
/// (the tolerant ISO-8601 strategy) — PostgresKit's built-in JSON decoder uses
/// a numeric date strategy and would choke on the string timestamps.
enum PostStore {
    static let maxHashtagsPerPost = 10

    /// Port of `sanitizeHashtags` — strip all whitespace, cap 100 chars, cap 10
    /// tags, case-insensitive dedupe (first casing wins).
    static func sanitizeHashtags(_ tags: [String]?) -> [String] {
        guard let tags else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            if out.count >= maxHashtagsPerPost { break }
            let trimmed = String(raw.filter { !$0.isWhitespace }.prefix(100))
            if trimmed.isEmpty { continue }
            let key = trimmed.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    // MARK: buildPostSelect + clauses  (viewer id inlined via \(uuid:) at each use)

    /// The event / poll / job sub-objects for posts aliased `p`, as seen by
    /// viewer `v` (their RSVP, vote and interest), each followed by a comma.
    /// Shared by every post query and the recommended feed, so no list of
    /// posts can come back without them.
    static func typeDataColumns(_ v: String) -> SQLQueryString {
        """
          (CASE WHEN p.post_type = 'event' THEN (
            SELECT json_build_object('id', ce.id, 'title', ce.title, 'location', ce.location,
              'starts_at', ce.starts_at, 'ends_at', ce.ends_at, 'rsvp_count', ce.rsvp_count,
              'user_rsvp', (SELECT er.status FROM event_rsvps er WHERE er.event_id = ce.id AND er.user_id = \(uuid: v)))
            FROM community_events ce WHERE ce.post_id = p.id
          ) ELSE NULL END)::text AS event_data,
          (CASE WHEN p.post_type = 'poll' THEN json_build_object(
            'options', (SELECT json_agg(json_build_object('id', po.id, 'text', po.text, 'vote_count', po.vote_count,
              'position', po.position, 'ends_at', po.ends_at) ORDER BY po.position) FROM poll_options po WHERE po.post_id = p.id),
            'user_vote', (SELECT pv.poll_option_id::TEXT FROM poll_votes pv JOIN poll_options po2 ON po2.id = pv.poll_option_id
              WHERE po2.post_id = p.id AND pv.user_id = \(uuid: v)))
          ELSE NULL END)::text AS poll_data,
          (CASE WHEN p.post_type = 'job' THEN (
            SELECT json_build_object('id', jp.id, 'title', jp.title, 'company', COALESCE(jc.name, jp.company), 'location', jp.location,
              'employment_type', jp.employment_type, 'salary_range', jp.salary_range,
              'application_deadline', jp.application_deadline, 'interested_count', jp.interested_count,
              'user_interested', EXISTS(SELECT 1 FROM job_interests ji WHERE ji.job_id = jp.id AND ji.user_id = \(uuid: v)),
              'company_id', jp.company_id, 'company_logo_url', jc.logo_url, 'company_verified', COALESCE(jc.is_verified, FALSE),
              'work_format', jp.work_format, 'level', jp.level, 'salary_min', jp.salary_min, 'salary_max', jp.salary_max,
              'skills', COALESCE((SELECT json_agg(js.skill ORDER BY js.skill) FROM job_skills js WHERE js.job_id = jp.id), '[]'))
            FROM job_posts jp LEFT JOIN companies jc ON jc.id = jp.company_id WHERE jp.post_id = p.id
          ) ELSE NULL END)::text AS job_data,
        """
    }

    static func buildPostSelect(_ v: String) -> SQLQueryString {
        let dnP  = PersonaSQL.expr("display_name", modeRef: "p.mode")
        let avP  = PersonaSQL.expr("avatar_url", modeRef: "p.mode")
        let dnSp = PersonaSQL.expr("display_name", modeRef: "sp.mode", alias: "su")
        let avSp = PersonaSQL.expr("avatar_url", modeRef: "sp.mode", alias: "su")
        return """
        SELECT
          p.id::text AS id, p.content, p.mode, p.privacy, p.image_urls[1] AS image_url, p.image_urls, p.image_alts, p.status::text AS status, p.publish_at,
          p.lang, \(unsafeRaw: TranslationService.translatedColumn("p")) AS translated_text, p.article_title, p.link_url,
          p.like_count, p.comment_count, p.share_count, p.created_at,
          p.post_type, p.is_pinned, p.pinned_at, p.shared_post_id::text AS shared_post_id,
          EXISTS(SELECT 1 FROM post_likes pl WHERE pl.post_id = p.id AND pl.user_id = \(uuid: v)) AS is_liked,
          EXISTS(SELECT 1 FROM saved_posts sp2 WHERE sp2.post_id = p.id AND sp2.user_id = \(uuid: v)) AS is_saved,
          (CASE WHEN p.shared_post_id IS NOT NULL THEN (
            SELECT json_build_object(
              'id', sp.id, 'content', sp.content, 'image_url', sp.image_urls[1], 'image_urls', sp.image_urls, 'image_alts', sp.image_alts, 'lang', sp.lang, 'translated_text', \(unsafeRaw: TranslationService.translatedColumn("sp")),
              'link_url', sp.link_url, 'article_title', sp.article_title, 'created_at', sp.created_at,
              'author', json_build_object('id', su.id, 'username', su.username,
                'display_name', \(unsafeRaw: dnSp), 'avatar_color', su.avatar_color, 'avatar_url', \(unsafeRaw: avSp)))
            FROM posts sp JOIN users su ON su.id = sp.author_id
            WHERE sp.id = p.shared_post_id AND sp.status = 'posted'
              AND (sp.privacy = 'public' OR sp.author_id = \(uuid: v)
                OR (sp.privacy = 'friends' AND EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted'
                     AND ((c.requester_id = sp.author_id AND c.addressee_id = \(uuid: v))
                       OR (c.addressee_id = sp.author_id AND c.requester_id = \(uuid: v))))))
              AND (sp.community_id IS NULL OR sp.author_id = \(uuid: v)
                OR EXISTS (SELECT 1 FROM communities co WHERE co.id = sp.community_id AND co.privacy = 'public')
                OR EXISTS (SELECT 1 FROM community_members cm WHERE cm.community_id = sp.community_id AND cm.user_id = \(uuid: v)))
          ) ELSE NULL END)::text AS shared_post,
          COALESCE(json_agg(DISTINCT pt.tag) FILTER (WHERE pt.tag IS NOT NULL AND pt.source = 'user'), '[]')::text AS tags,
          json_build_object('id', u.id, 'username', u.username, 'display_name', \(unsafeRaw: dnP),
            'avatar_color', u.avatar_color, 'avatar_url', \(unsafeRaw: avP),
            'job_title', u.job_title, 'company', u.company)::text AS author,
          \(typeDataColumns(v))
          (CASE WHEN p.community_id IS NOT NULL THEN (
            SELECT json_build_object('id', co.id, 'name', co.name, 'icon_emoji', co.icon_emoji, 'avatar_url', co.avatar_url)
            FROM communities co WHERE co.id = p.community_id
          ) ELSE NULL END)::text AS community
        FROM posts p
        JOIN users u ON u.id = p.author_id
        LEFT JOIN post_tags pt ON pt.post_id = p.id
        """
    }

    static func privacyClause(_ v: String) -> SQLQueryString {
        """
        (p.privacy = 'public' OR p.author_id = \(uuid: v)
         OR (p.privacy = 'friends' AND EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted'
              AND ((c.requester_id = p.author_id AND c.addressee_id = \(uuid: v))
                OR (c.addressee_id = p.author_id AND c.requester_id = \(uuid: v))))))
        """
    }
    static func communityVisibilityClause(_ v: String) -> SQLQueryString {
        """
        (p.community_id IS NULL OR p.author_id = \(uuid: v)
         OR EXISTS (SELECT 1 FROM communities co WHERE co.id = p.community_id AND co.privacy = 'public')
         OR EXISTS (SELECT 1 FROM community_members cm WHERE cm.community_id = p.community_id AND cm.user_id = \(uuid: v)))
        """
    }
    /// Feed-only suppression: a community you've muted still exists (its own
    /// page, findById, listSaved are all unaffected — this is deliberately
    /// NOT folded into `communityVisibilityClause`, which those still use
    /// unchanged), but its posts drop out of your Feed. Your own posts in a
    /// muted community still show (muting isn't "hide myself from myself").
    static func notMutedClause(_ v: String) -> SQLQueryString {
        """
        (p.author_id = \(uuid: v) OR NOT EXISTS (SELECT 1 FROM community_members cmMute
          WHERE cmMute.community_id = p.community_id AND cmMute.user_id = \(uuid: v) AND cmMute.muted = TRUE))
        """
    }
    static func notBlockedClause(_ v: String) -> SQLQueryString {
        """
        NOT EXISTS (SELECT 1 FROM user_blocks ub
          WHERE (ub.blocker_id = \(uuid: v) AND ub.blocked_id = p.author_id)
             OR (ub.blocker_id = p.author_id AND ub.blocked_id = \(uuid: v)))
        """
    }
    static func notHiddenClause(_ v: String) -> SQLQueryString {
        "NOT EXISTS (SELECT 1 FROM hidden_posts hp WHERE hp.user_id = \(uuid: v) AND hp.post_id = p.id)"
    }
    /// Muted words (migration 042): text folded the way post search folds it —
    /// accents stripped, lowercased, every run of non-alphanumerics one space,
    /// padded both ends — so `LIKE '% word %'` is a whole-word (or whole-phrase)
    /// match: "chet" hides "chết", "ass" leaves "class" alone. The word is
    /// folded the same way, which also strips any LIKE wildcards from it.
    static func folded(_ textSQL: String) -> String {
        "(' ' || regexp_replace(unaccent(lower(coalesce(\(textSQL), ''))), '[^[:alnum:]]+', ' ', 'g') || ' ')"
    }
    private static let mutedPattern = "'% ' || btrim(regexp_replace(unaccent(lower(mw.word)), '[^[:alnum:]]+', ' ', 'g')) || ' %'"

    /// Whether `textSQL` contains one of the viewer's unexpired muted words for
    /// the mode in `modeRef` (a SQL column reference, never user input).
    static func mutedWordHit(_ v: String, textSQL: String, modeRef: String) -> SQLQueryString {
        """
        EXISTS (SELECT 1 FROM muted_words mw WHERE mw.user_id = \(uuid: v) AND mw.mode = \(unsafeRaw: modeRef)
          AND (mw.expires_at IS NULL OR mw.expires_at > NOW())
          AND \(unsafeRaw: folded(textSQL)) LIKE \(unsafeRaw: mutedPattern))
        """
    }

    /// Hides a post when its text, title or a visible tag contains one of the
    /// viewer's muted words for the post's mode. Never hides your own posts.
    static func notMutedWordsClause(_ v: String) -> SQLQueryString {
        """
        (p.author_id = \(uuid: v) OR NOT EXISTS (SELECT 1 FROM muted_words mw
          WHERE mw.user_id = \(uuid: v) AND mw.mode = p.mode AND (mw.expires_at IS NULL OR mw.expires_at > NOW())
            AND (\(unsafeRaw: folded("coalesce(p.content, '') || ' ' || coalesce(p.article_title, '')")) LIKE \(unsafeRaw: mutedPattern)
              OR EXISTS (SELECT 1 FROM post_tags ptm WHERE ptm.post_id = p.id AND ptm.source = 'user'
                         AND \(unsafeRaw: folded("ptm.tag")) LIKE \(unsafeRaw: mutedPattern)))))
        """
    }

    static func connectionsOnlyClause(_ v: String) -> SQLQueryString {
        """
        (p.author_id = \(uuid: v) OR EXISTS (SELECT 1 FROM connections c2 WHERE c2.status = 'accepted'
          AND ((c2.requester_id = p.author_id AND c2.addressee_id = \(uuid: v))
            OR (c2.addressee_id = p.author_id AND c2.requester_id = \(uuid: v)))))
        """
    }

    /// The Following feed: personal posts by people the viewer follows in that
    /// mode who aren't their friends there (friends have the Connections feed).
    /// privacyClause already limits these to public posts.
    static func followingOnlyClause(_ v: String) -> SQLQueryString {
        """
        (p.community_id IS NULL
         AND EXISTS (SELECT 1 FROM follows fw WHERE fw.follower_id = \(uuid: v)
                     AND fw.followee_id = p.author_id AND fw.mode = p.mode)
         AND NOT EXISTS (SELECT 1 FROM connections c3 WHERE c3.status = 'accepted' AND c3.mode = p.mode
              AND ((c3.requester_id = p.author_id AND c3.addressee_id = \(uuid: v))
                OR (c3.addressee_id = p.author_id AND c3.requester_id = \(uuid: v)))))
        """
    }

    // MARK: row → PostObject

    struct PostRow: Decodable {
        var id: String
        var content: String?
        var mode: String
        var privacy: String
        var image_url: String?
        var image_urls: [String]?
        var image_alts: [String]?
        var article_title: String?
        var link_url: String?
        var status: String
        var publish_at: Date?
        var lang: String?
        var translated_text: String?
        var like_count: Int
        var comment_count: Int
        var share_count: Int
        var created_at: Date
        var post_type: String
        var is_pinned: Bool
        var pinned_at: Date?
        var shared_post_id: String?
        var is_liked: Bool
        var is_saved: Bool
        var shared_post: String?
        var tags: String
        var author: String
        var event_data: String?
        var poll_data: String?
        var job_data: String?
        var community: String?
    }

    static func map(_ r: PostRow) throws -> PostObject {
        let dec = JSONCoding.makeDecoder()
        func parse<T: Decodable>(_ s: String?, _ t: T.Type) throws -> T? {
            guard let s, s != "null" else { return nil }
            return try dec.decode(T.self, from: Data(s.utf8))
        }
        return PostObject(
            id: r.id, content: r.content, mode: r.mode, privacy: r.privacy,
            image_url: r.image_url, image_urls: r.image_urls, image_alts: r.image_alts, article_title: r.article_title,
            link_url: r.link_url, status: r.status == "posted" ? nil : r.status, publish_at: r.publish_at,
            lang: r.lang, translated_text: r.translated_text,
            like_count: r.like_count, comment_count: r.comment_count, share_count: r.share_count,
            created_at: r.created_at, post_type: r.post_type, is_pinned: r.is_pinned, pinned_at: r.pinned_at,
            shared_post_id: r.shared_post_id, is_liked: r.is_liked, is_saved: r.is_saved,
            shared_post: try parse(r.shared_post, PostObject.SharedPost.self),
            tags: (try? dec.decode([String].self, from: Data(r.tags.utf8))) ?? [],
            author: try dec.decode(PostObject.PostAuthor.self, from: Data(r.author.utf8)),
            event_data: try parse(r.event_data, PostObject.EventData.self),
            poll_data: try parse(r.poll_data, PostObject.PollData.self),
            job_data: try parse(r.job_data, PostObject.JobData.self),
            community: try parse(r.community, PostObject.CommunityRef.self)
        )
    }

    // MARK: queries

    struct FeedFilters {
        var mode: String?
        var authorID: String?
        var tag: String?
        /// Keyword search over content and tags, ranked by `postRelevance`
        /// (accent-insensitive, word by word) instead of newest-first.
        var search: String?
        var connectionsOnly: Bool
        /// People the viewer follows (in the post's mode) but isn't friends with.
        var followingOnly = false
        var limit: Int
        var offset: Int
    }

    static func feedWhere(_ v: String, _ f: FeedFilters) -> SQLQueryString {
        var w: SQLQueryString = "WHERE p.status = 'posted' AND "
        w = w + communityVisibilityClause(v) + " AND " + notMutedClause(v) + " AND "
        w = w + privacyClause(v) + " AND " + notBlockedClause(v) + " AND " + notHiddenClause(v)
        w = w + " AND " + notMutedWordsClause(v)
        if f.connectionsOnly { w = w + " AND " + connectionsOnlyClause(v) }
        if f.followingOnly { w = w + " AND " + followingOnlyClause(v) }
        if let m = f.mode { w = w + " AND p.mode = \(bind: m)" }
        // Author-scoped listing is only ever a Profile screen (own or someone
        // else's) — community posts belong on that community's own page, not
        // mixed into a person's profile feed, so exclude them here even
        // though they'd otherwise pass communityVisibilityClause fine.
        if let a = f.authorID { w = w + " AND p.author_id = \(uuid: a) AND p.community_id IS NULL" }
        if let t = f.tag {
            w = w + " AND EXISTS (SELECT 1 FROM post_tags ptf WHERE ptf.post_id = p.id AND LOWER(ptf.tag) = LOWER(\(bind: t)) AND ptf.source = 'user')"
        }
        if let s = f.search {
            w = w + " AND " + postMatches(SearchTokenizer.words(s))
        }
        return w
    }

    static func findAll(viewer: String, _ f: FeedFilters, on db: any SQLDatabase) async throws -> [PostObject] {
        // No usable words (e.g. only punctuation) → postMatches already
        // filters everything out; don't emit a bare `0` either, which
        // Postgres reads as ORDER BY column position 0 and rejects.
        let words = f.search.map(SearchTokenizer.words) ?? []
        let order: SQLQueryString = words.isEmpty
            ? "p.created_at DESC"
            : postRelevance(words) + " DESC, p.created_at DESC"
        let q = buildPostSelect(viewer) + " " + feedWhere(viewer, f)
            + " GROUP BY p.id, u.id ORDER BY " + order + " LIMIT \(bind: f.limit) OFFSET \(bind: f.offset)"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }

    // MARK: keyword relevance

    /// Content folded for word matching: accents stripped, lowercased, and
    /// every run of non-alphanumerics turned into one space, with a leading
    /// space so "% word" matches the start of any word — including the first.
    private static let contentWords = "(' ' || regexp_replace(unaccent(lower(coalesce(p.content, ''))), '[^[:alnum:]]+', ' ', 'g'))"

    /// Only tags the author wrote count. AI tags exist to classify posts for
    /// AI search and are never shown, so they can't match a keyword either.
    private static func tagIs(_ w: String) -> SQLQueryString {
        "EXISTS (SELECT 1 FROM post_tags pts WHERE pts.post_id = p.id AND pts.source = 'user' AND unaccent(lower(pts.tag)) = unaccent(\(bind: w)))"
    }

    private static func contentStarts(_ w: String) -> SQLQueryString {
        "\(unsafeRaw: contentWords) LIKE '% ' || unaccent(\(bind: w)) || '%'"
    }

    private static func contentHas(_ w: String) -> SQLQueryString {
        "\(unsafeRaw: contentWords) LIKE '%' || unaccent(\(bind: w)) || '%'"
    }

    /// At least one word appears in the content or equals a visible tag.
    /// A query with no usable words (only punctuation) matches nothing.
    private static func postMatches(_ words: [String]) -> SQLQueryString {
        guard !words.isEmpty else { return "FALSE" }
        var any: SQLQueryString = "FALSE"
        for w in words { any = any + " OR " + tagIs(w) + " OR " + contentHas(w) }
        return "(" + any + ")"
    }

    /// Per word: a matching tag +30, the start of a word in the content +10,
    /// merely inside one +4; +15 when every word matched somewhere. Ties fall
    /// to newest (see `findAll`). Callers pass at least one word.
    static func postRelevance(_ words: [String]) -> SQLQueryString {
        var score: SQLQueryString = "(0"
        var everyWord: SQLQueryString = "TRUE"
        for w in words {
            score = score
                + " + CASE WHEN " + tagIs(w) + " THEN 30 ELSE 0 END"
                + " + CASE WHEN " + contentStarts(w) + " THEN 10 WHEN " + contentHas(w) + " THEN 4 ELSE 0 END"
            everyWord = everyWord + " AND (" + tagIs(w) + " OR " + contentHas(w) + ")"
        }
        return score + " + CASE WHEN " + everyWord + " THEN 15 ELSE 0 END)"
    }

    /// Loads `ids` as full feed posts, keeping only those `viewer` may see
    /// under exactly the feed's rules (status, privacy, blocks, community
    /// visibility, hidden, muted). Order is not preserved — callers re-sort.
    static func findVisible(_ ids: [String], viewer: String, on db: any SQLDatabase) async throws -> [PostObject] {
        guard !ids.isEmpty else { return [] }
        let all = FeedFilters(mode: nil, authorID: nil, tag: nil, search: nil, connectionsOnly: false, limit: 0, offset: 0)
        let q = buildPostSelect(viewer) + " " + feedWhere(viewer, all)
            + " AND p.id = ANY(\(bind: ids)::uuid[]) GROUP BY p.id, u.id"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }

    static func countAll(viewer: String, _ f: FeedFilters, on db: any SQLDatabase) async throws -> Int {
        struct N: Decodable { let n: Int }
        let q: SQLQueryString = "SELECT COUNT(*)::int AS n FROM posts p " + feedWhere(viewer, f)
        return try await db.raw(q).first(decoding: N.self)?.n ?? 0
    }

    static let maxAltLength = 300

    /// Alt text lined up with `count` media items: each entry trimmed and
    /// capped, missing ones ''. nil when there's no media or nothing written,
    /// so posts without alt text store NULL rather than a row of blanks.
    static func cleanAlts(_ raw: [String]?, count: Int) -> [String]? {
        guard let raw, count > 0 else { return nil }
        let alts = (0..<count).map { i -> String in
            guard i < raw.count else { return "" }
            return String(raw[i].trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxAltLength))
        }
        return alts.allSatisfy(\.isEmpty) ? nil : alts
    }

    /// Sets a post's alt text to match its current media.
    @discardableResult
    static func setImageAlts(_ id: String, _ raw: [String]?, on db: any SQLDatabase) async throws -> [String]? {
        struct U: Decodable { let image_urls: [String]? }
        let urls = try await db.raw("SELECT image_urls FROM posts WHERE id = \(uuid: id)").first(decoding: U.self)?.image_urls
        let alts = cleanAlts(raw, count: urls?.count ?? 0)
        try await db.raw("UPDATE posts SET image_alts = \(bind: alts) WHERE id = \(uuid: id)").run()
        return alts
    }

    /// `includeOwnUnpublished`: also return the viewer's own draft or
    /// scheduled post — only for its author, right after saving it.
    static func findById(_ id: String, viewer: String, includeOwnUnpublished: Bool = false,
                         on db: any SQLDatabase) async throws -> PostObject? {
        let status: SQLQueryString = includeOwnUnpublished
            ? "(p.status = 'posted' OR (p.author_id = \(uuid: viewer) AND p.status IN ('draft', 'scheduled')))"
            : "p.status = 'posted'"
        let q = buildPostSelect(viewer)
            + " WHERE p.id = \(uuid: id) AND " + status + " AND "
            + privacyClause(viewer) + " AND " + notBlockedClause(viewer) + " AND " + communityVisibilityClause(viewer)
            + " GROUP BY p.id, u.id"
        guard let row = try await db.raw(q).first(decoding: PostRow.self) else { return nil }
        return try map(row)
    }

    // MARK: drafts & scheduled (migration 047)

    /// The author's drafts and scheduled posts, both modes, newest first —
    /// with everything the composer needs to reopen one.
    static func listUnpublished(_ author: String, on db: any SQLDatabase) async throws -> [PostObject] {
        let q = buildPostSelect(author)
            + " WHERE p.author_id = \(uuid: author) AND p.status IN ('draft', 'scheduled')"
            + " GROUP BY p.id, u.id ORDER BY p.status DESC, COALESCE(p.publish_at, p.updated_at, p.created_at) DESC"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }

    /// Whether `id` is one of `author`'s drafts or scheduled posts.
    static func isOwnUnpublished(_ id: String, author: String, on db: any SQLDatabase) async throws -> Bool {
        struct I: Decodable { let id: String }
        return try await db.raw("""
            SELECT id::text AS id FROM posts
            WHERE id = \(uuid: id) AND author_id = \(uuid: author) AND status IN ('draft', 'scheduled')
            """).first(decoding: I.self) != nil
    }

    /// Removes a draft or scheduled post outright (it was never public, so
    /// there's no Recently Deleted for it). Its rows in poll_options,
    /// community_events, job_posts and post_tags go with it (ON DELETE CASCADE).
    @discardableResult
    static func deleteUnpublished(_ id: String, author: String, on db: any SQLDatabase) async throws -> Bool {
        struct I: Decodable { let id: String }
        return try await db.raw("""
            DELETE FROM posts WHERE id = \(uuid: id) AND author_id = \(uuid: author) AND status IN ('draft', 'scheduled')
            RETURNING id::text AS id
            """).first(decoding: I.self) != nil
    }

    struct PostMeta: Decodable {
        var id: String
        var author_id: String
        var community_id: String?
        var post_type: String
    }
    static func findMeta(_ id: String, on db: any SQLDatabase) async throws -> PostMeta? {
        // `::text` matters: a raw `uuid` column decodes to Swift's uppercase
        // UUID.uuidString form, while req.userID is the lowercased JWT
        // subject — without the cast, every ownership check built on this
        // (delete/edit/restore) can never match, silently 403ing for the
        // genuine owner. Same fix already applied to comments in
        // InteractionsController.swift.
        // Drafts and scheduled posts are invisible here: nobody can vote on,
        // report, like, edit or remove one through the normal post routes —
        // they're managed only through the drafts endpoints.
        try await db.raw("SELECT id::text AS id, author_id::text AS author_id, community_id::text AS community_id, post_type FROM posts WHERE id = \(uuid: id) AND status NOT IN ('draft', 'scheduled')")
            .first(decoding: PostMeta.self)
    }

    // MARK: create

    struct CreateArgs {
        var authorID: String
        var content: String
        var mode: String
        var privacy: String
        var imageUrl: String?
        var imageUrls: [String]?
        var linkUrl: String?
        var articleTitle: String?
        var sharedPostID: String?
        var hashtags: [String]
        var publishing: Publishing = .now
    }

    static func create(_ a: CreateArgs, on db: AppDatabase) async throws -> PostObject? {
        let validPrivacy = ["public", "friends", "only_me"].contains(a.privacy) ? a.privacy : "public"
        let urls: [String]? = (a.imageUrls?.isEmpty == false) ? a.imageUrls : (a.imageUrl.map { [$0] })
        var newID = ""
        try await db.tx { t in
            struct R: Decodable { let id: String }
            let row = try await t.raw("""
                INSERT INTO posts (author_id, content, mode, privacy, image_urls, link_url, article_title, shared_post_id,
                                   status, publish_at)
                VALUES (\(uuid: a.authorID), \(bind: a.content), \(bind: a.mode), \(bind: validPrivacy),
                        \(bind: urls), \(bind: a.linkUrl), \(bind: a.articleTitle), \(uuid: a.sharedPostID),
                        \(bind: a.publishing.status)::post_status, \(bind: a.publishing.publishAt))
                RETURNING id
                """).first(decoding: R.self)
            newID = row!.id
            if a.publishing.isLive {
                try await t.raw("UPDATE users SET post_count = post_count + 1 WHERE id = \(uuid: a.authorID)").run()
            }
            let clean = sanitizeHashtags(a.hashtags)
            if !clean.isEmpty {
                try await t.raw("""
                    INSERT INTO post_tags (post_id, tag, source)
                    SELECT \(uuid: newID), UNNEST(\(bind: clean)::text[]), 'user'
                    ON CONFLICT (post_id, tag) DO NOTHING
                    """).run()
            }
        }
        return try await findById(newID, viewer: a.authorID, includeOwnUnpublished: !a.publishing.isLive, on: db.sql())
    }

    // MARK: update / delete / restore / lists

    /// Returns `.updated(post)`, `.notFound`, or `.empty`.
    enum UpdateResult { case updated(PostObject); case notFound; case empty }

    static func updatePost(
        _ id: String, content: String?, contentProvided: Bool, privacy: String?,
        imageUrl: String?, imageUrls: [String]?, linkUrl: String?, articleTitle: String?,
        on db: any SQLDatabase
    ) async throws -> UpdateResult {
        let validPrivacy = ["public", "friends", "only_me"].contains(privacy ?? "") ? privacy : nil
        let urls: [String]? = (imageUrls?.isEmpty == false) ? imageUrls : (imageUrl.map { [$0] })

        struct C: Decodable { let content: String? }
        guard let existing = try await db.raw("SELECT content FROM posts WHERE id = \(uuid: id) AND status = 'posted'")
            .first(decoding: C.self) else { return .notFound }

        let finalContent = contentProvided ? content : existing.content
        let hasContent = !(finalContent?.trimmedText.isEmpty ?? true)
        let hasImages = (urls?.isEmpty == false)
        let hasLink = !(linkUrl?.isEmpty ?? true)
        if !hasContent && !hasImages && !hasLink { return .empty }

        struct R: Decodable { let id: String; let author_id: String }
        guard let row = try await db.raw("""
            UPDATE posts SET
              content = CASE WHEN \(bind: contentProvided) THEN \(bind: contentProvided ? content : nil) ELSE content END,
              privacy = COALESCE(\(bind: validPrivacy), privacy),
              image_urls = \(bind: urls), link_url = \(bind: linkUrl), article_title = \(bind: articleTitle),
              updated_at = NOW()
            WHERE id = \(uuid: id) AND status = 'posted'
            RETURNING id, author_id
            """).first(decoding: R.self) else { return .notFound }
        guard let post = try await findById(row.id, viewer: row.author_id, on: db) else { return .notFound }
        return .updated(post)
    }

    struct DeleteRow: Decodable { let id: String; let author_id: String; let community_id: String? }

    static func softDelete(_ id: String, on db: any SQLDatabase) async throws -> DeleteRow? {
        guard let row = try await db.raw("""
            UPDATE posts SET status = 'deleted', deleted_at = NOW(), updated_at = NOW()
            WHERE id = \(uuid: id) AND status = 'posted'
            RETURNING id, author_id, community_id
            """).first(decoding: DeleteRow.self) else { return nil }
        try await db.raw("UPDATE users SET post_count = GREATEST(post_count - 1, 0) WHERE id = \(uuid: row.author_id)").run()
        return row
    }

    static func restore(_ id: String, requester: String, on db: any SQLDatabase) async throws -> PostObject? {
        guard let row = try await db.raw("""
            UPDATE posts SET status = 'posted', deleted_at = NULL, updated_at = NOW()
            WHERE id = \(uuid: id) AND author_id = \(uuid: requester) AND status = 'deleted'
            RETURNING id, author_id, community_id
            """).first(decoding: DeleteRow.self) else { return nil }
        try await db.raw("UPDATE users SET post_count = post_count + 1 WHERE id = \(uuid: row.author_id)").run()
        return try await findById(row.id, viewer: requester, on: db)
    }

    static func listDeleted(_ userID: String, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [PostObject] {
        let q = buildPostSelect(userID)
            + " WHERE p.author_id = \(uuid: userID) AND p.status = 'deleted' GROUP BY p.id, u.id"
            + " ORDER BY MAX(p.deleted_at) DESC LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }

    /// Port of `getPostsByCommunity` — pinned post first. `buildPostSelect`
    /// itself now projects `community` (needed so Feed posts carry it too,
    /// once Feed starts including community posts), so this no longer needs
    /// its own outer wrapper to merge it in.
    static func getPostsByCommunity(_ communityID: String, viewer: String, tag: String?, search: String? = nil, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [PostObject] {
        var q = buildPostSelect(viewer)
        q = q + " WHERE p.community_id = \(uuid: communityID) AND p.status = 'posted' AND " + notMutedWordsClause(viewer)
        if let tag {
            q = q + " AND EXISTS (SELECT 1 FROM post_tags ptf WHERE ptf.post_id = p.id AND LOWER(ptf.tag) = LOWER(\(bind: tag)) AND ptf.source = 'user')"
        }
        if let search {
            q = q + " AND p.content ILIKE '%' || \(bind: UserStore.escapeLike(search)) || '%'"
        }
        q = q + " GROUP BY p.id, u.id ORDER BY p.is_pinned DESC, p.created_at DESC LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }

    static func listSaved(_ userID: String, limit: Int, offset: Int, on db: any SQLDatabase) async throws -> [PostObject] {
        let q = buildPostSelect(userID)
            + " JOIN saved_posts sap ON sap.post_id = p.id AND sap.user_id = \(uuid: userID)"
            + " WHERE p.status = 'posted' AND " + privacyClause(userID) + " AND " + notBlockedClause(userID)
            + " AND " + communityVisibilityClause(userID)
            + " GROUP BY p.id, u.id, sap.created_at ORDER BY sap.created_at DESC LIMIT \(bind: limit) OFFSET \(bind: offset)"
        return try await db.raw(q).all(decoding: PostRow.self).map(map)
    }
}
