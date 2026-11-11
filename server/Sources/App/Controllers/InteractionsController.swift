import Vapor
import SQLKit

/// Likes, comments and shares. Mounted under `/api/posts/:id`. Inline `{error}`
/// bodies. A deleted comment stays deleted, apart from the author's Undo in
/// the few seconds the app shows it (`restoreComment`) and an overturned
/// moderation appeal (`ModerationService.restore`).
struct InteractionsController {
    static func register(routes: any RoutesBuilder) {
        routes.post("like", use: likePost)
        routes.get("comments", use: listComments)
        routes.post("comments", use: addComment)
        routes.delete("comments", ":commentId", use: deleteComment)
        routes.post("comments", ":commentId", "restore", use: restoreComment)
        routes.patch("comments", ":commentId", use: editComment)
        routes.get("comments", ":commentId", "history", use: commentHistory)
        routes.post("comments", ":commentId", "like", use: likeComment)
        routes.on(.POST, "hide", use: hide); routes.on(.DELETE, "hide", use: unhide)
        routes.on(.POST, "save", use: save); routes.on(.DELETE, "save", use: unsave)
        routes.on(.POST, "feedback", use: feedback); routes.on(.DELETE, "feedback", use: unfeedback)
    }

    struct VisibleMeta { let id: String; let authorID: String; let mode: String; let communityID: String? }

    /// `officialReads`: the official account may read, like and comment on a
    /// community post without joining (it still can't post or save there).
    static func visibleMeta(_ postID: String, viewer: String, officialReads: Bool = false,
                            _ db: any SQLDatabase) async throws -> VisibleMeta? {
        guard let post = try await PostStore.findById(postID, viewer: viewer, officialReads: officialReads, on: db) else { return nil }
        let meta = try await PostStore.findMeta(postID, on: db)
        return VisibleMeta(id: post.id, authorID: post.author.id, mode: post.mode, communityID: meta?.community_id)
    }

    static func personaAuthor(_ userID: String, mode: String, _ db: any SQLDatabase) async throws -> CommentObject.CommentAuthor {
        struct A: Decodable { let id: String; let display_name: String; let avatar_color: String?; let avatar_url: String? }
        let a = try await db.raw("""
            SELECT id::text AS id,
              \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "'\(mode)'", alias: "users")) AS display_name,
              avatar_color,
              \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "'\(mode)'", alias: "users")) AS avatar_url
            FROM users WHERE id = \(uuid: userID)
            """).first(decoding: A.self)!
        return .init(id: a.id, display_name: a.display_name, avatar_color: a.avatar_color, avatar_url: a.avatar_url)
    }

    // MARK: like post

    struct LikeResponse: Content { var liked: Bool; var like_count: Int }

    static func likePost(_ req: Request) async throws -> LikeResponse {
        let postID = req.parameters.get("id")!
        let db = req.db.sql()
        guard let meta = try await visibleMeta(postID, viewer: req.userID, officialReads: true, db) else {
            throw InlineError(.notFound, "Post not found")
        }
        try req.requireNotBanned(in: meta.mode)
        var liked = false
        try await req.db.tx { t in
            struct R: Decodable { let one: Int }
            let inserted = try await t.raw("INSERT INTO post_likes (post_id, user_id) VALUES (\(uuid: postID), \(uuid: req.userID)) ON CONFLICT DO NOTHING RETURNING 1 AS one")
                .first(decoding: R.self)
            if inserted != nil {
                try await t.raw("UPDATE posts SET like_count = like_count + 1 WHERE id = \(uuid: postID)").run()
                liked = true
            } else {
                struct D: Decodable { let post_id: String }
                let del = try await t.raw("DELETE FROM post_likes WHERE post_id = \(uuid: postID) AND user_id = \(uuid: req.userID) RETURNING post_id").all(decoding: D.self)
                if !del.isEmpty {
                    try await t.raw("UPDATE posts SET like_count = GREATEST(like_count - 1, 0) WHERE id = \(uuid: postID)").run()
                }
                liked = false
            }
        }
        struct LC: Decodable { let like_count: Int }
        let lc = try await db.raw("SELECT like_count FROM posts WHERE id = \(uuid: postID)").first(decoding: LC.self)!
        if liked {
            NotifyService.dispatchSocial(req, .init(
                type: "post_liked", actorID: req.userID, recipientID: meta.authorID, postID: postID))
        }
        // TODO(phase 4): community_post_liked socket emit for open community viewers
        return LikeResponse(liked: liked, like_count: lc.like_count)
    }

    // MARK: comments list / add / delete / edit / like

    struct ReplyPlacement: Equatable {
        let parentID: String
        let replyToID: String
    }

    /// Where a reply is stored. Threads are three levels deep (comment →
    /// reply → reply-to-reply): answering a top-level comment or a reply nests
    /// under it, but answering a third-level reply keeps the new one at that
    /// level, beside it, under the same parent. `replyToID` is always the
    /// comment answered.
    static func replyPlacement(targetID: String, targetParentID: String?, targetDepth: Int) -> ReplyPlacement {
        if targetDepth >= 3, let targetParentID {
            return ReplyPlacement(parentID: targetParentID, replyToID: targetID)
        }
        return ReplyPlacement(parentID: targetID, replyToID: targetID)
    }

    static func clampLimit(_ v: Int?, _ def: Int, _ hi: Int) -> Int { min(max(v ?? def, 1), hi) }

    static func listComments(_ req: Request) async throws -> CommentsListResponse {
        let postID = req.parameters.get("id")!
        let db = req.db.sql()
        let limit = clampLimit(try? req.query.get(Int.self, at: "limit"), 50, 100)
        let offset = req.pageOffset
        guard try await visibleMeta(postID, viewer: req.userID, officialReads: true, db) != nil else {
            throw InlineError(.notFound, "Post not found")
        }
        struct Row: Decodable {
            let id: String; let content: String?; let created_at: Date
            let parent_comment_id: String?; let like_count: Int; let is_liked: Bool; let author: String
            let reply_to: String?; let muted: Bool
            let lang: String?; let translated_text: String?; let image_url: String?; let content_format: String?
            let edited_at: Date?
        }
        let rows = try await db.raw("""
            SELECT c.id, c.content, c.created_at, c.parent_comment_id, c.like_count,
              EXISTS(SELECT 1 FROM comment_likes cl WHERE cl.comment_id = c.id AND cl.user_id = \(uuid: req.userID)) AS is_liked,
              json_build_object('id', u.id, 'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "p.mode")),
                'avatar_color', u.avatar_color, 'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "p.mode")),
                'is_official', u.app_role = 'admin')::text AS author,
              CASE WHEN rc.id IS NULL THEN NULL ELSE json_build_object('id', ru.id,
                'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "p.mode", alias: "ru")))::text END AS reply_to,
              (c.author_id <> \(uuid: req.userID) AND \(PostStore.mutedWordHit(req.userID, textSQL: "c.content", modeRef: "p.mode"))) AS muted,
              c.lang, \(unsafeRaw: TranslationService.translatedColumn("c")) AS translated_text, c.image_url, c.content_format, c.edited_at
            FROM comments c JOIN posts p ON p.id = c.post_id JOIN users u ON u.id = c.author_id
            LEFT JOIN comments rc ON rc.id = COALESCE(c.reply_to_comment_id, c.parent_comment_id)
            LEFT JOIN users ru ON ru.id = rc.author_id
            WHERE c.post_id = \(uuid: postID) AND c.status = 'posted'
              AND \(AccountBans.visible(userRef: "c.author_id", modeColumn: "p.mode", viewer: req.userID))
            ORDER BY c.created_at ASC LIMIT \(bind: limit) OFFSET \(bind: offset)
            """).all(decoding: Row.self)
        struct N: Decodable { let n: Int }
        let total = try await db.raw("SELECT COUNT(*)::int AS n FROM comments WHERE post_id = \(uuid: postID) AND status = 'posted'")
            .first(decoding: N.self)!.n
        let dec = JSONCoding.makeDecoder()
        let comments = try rows.map { r -> CommentObject in
            CommentObject(id: r.id, content: r.content, created_at: r.created_at,
                          parent_comment_id: r.parent_comment_id, like_count: r.like_count, is_liked: r.is_liked,
                          author: try dec.decode(CommentObject.CommentAuthor.self, from: Data(r.author.utf8)),
                          reply_to: try r.reply_to.map { try dec.decode(CommentObject.ReplyTo.self, from: Data($0.utf8)) },
                          muted: r.muted, lang: r.lang, translated_text: r.translated_text, image_url: r.image_url,
                          content_format: r.content_format, edited_at: r.edited_at)
        }
        return CommentsListResponse(data: comments, total: total)
    }

    static let maxCommentLength = 1000

    /// `comments.content` has CHECK (char_length(content) <= 1000), which
    /// counts code points, not the grapheme clusters Swift's `count` does.
    static func validateCommentLength(_ content: String) throws {
        guard content.unicodeScalars.count <= maxCommentLength else {
            throw InlineError(.badRequest, "Comment must be at most \(maxCommentLength) characters")
        }
    }

    struct AddCommentBody: Content { var content: String?; var parent_comment_id: String?; var image_url: String?; var content_format: String?; var confirm: Bool? }

    static func addComment(_ req: Request) async throws -> Response {
        try req.requireRoom(for: .comment)
        let postID = req.parameters.get("id")!
        let db = req.db.sql()
        let b = try req.content.decode(AddCommentBody.self)
        let content = b.content?.trimmedText ?? ""
        try validateCommentLength(content)
        try ModerationGate.check([content], .chat, confirm: b.confirm ?? false)
        try req.requireNoLinkToStrangers(in: content)
        // Only a photo uploaded here, not a link to someone else's image.
        let imageURL = MediaPath.storable(b.image_url)
        if let imageURL, !imageURL.hasPrefix("/uploads/") || imageURL.hasPrefix("/uploads/messages/") {
            throw InlineError(.badRequest, "image_url must be an uploaded photo")
        }
        guard !content.isEmpty || imageURL != nil else {
            throw InlineError(.badRequest, "content or image_url is required")
        }
        guard let meta = try await visibleMeta(postID, viewer: req.userID, officialReads: true, db) else {
            throw InlineError(.notFound, "Post not found")
        }
        try req.requireNotBanned(in: meta.mode)
        try req.requireNotRestricted(in: meta.mode)
        // `parent_comment_id` in the body is the comment being answered; where
        // the reply is stored can differ (see `replyPlacement`).
        var placement: ReplyPlacement? = nil
        var answeredAuthorID: String? = nil
        if let targetID = b.parent_comment_id {
            struct P: Decodable { let id: String; let parent_comment_id: String?; let author_id: String }
            guard let target = try await db.raw("""
                SELECT id, parent_comment_id, author_id::text AS author_id FROM comments
                WHERE id = \(uuid: targetID) AND post_id = \(uuid: postID) AND status = 'posted'
                """).first(decoding: P.self) else { throw InlineError(.notFound, "Parent comment not found") }
            var targetDepth = 1
            if let parentID = target.parent_comment_id {
                let parent = try await db.raw("SELECT id, parent_comment_id, author_id::text AS author_id FROM comments WHERE id = \(uuid: parentID)")
                    .first(decoding: P.self)
                targetDepth = parent?.parent_comment_id == nil ? 2 : 3
            }
            placement = replyPlacement(targetID: target.id, targetParentID: target.parent_comment_id, targetDepth: targetDepth)
            answeredAuthorID = target.author_id
        }
        struct C: Decodable {
            let id: String; let content: String?; let created_at: Date; let parent_comment_id: String?
            let like_count: Int; let image_url: String?; let content_format: String?
        }
        let format = PostStore.contentFormats.contains(b.content_format ?? "") ? b.content_format! : "plain"
        var created: C!
        try await req.db.tx { t in
            created = try await t.raw("""
                INSERT INTO comments (post_id, author_id, content, parent_comment_id, reply_to_comment_id, image_url, content_format)
                VALUES (\(uuid: postID), \(uuid: req.userID), \(bind: content), \(uuid: placement?.parentID),
                        \(uuid: placement?.replyToID), \(bind: imageURL), \(bind: format))
                RETURNING id, content, created_at, parent_comment_id, like_count, image_url, content_format
                """).first(decoding: C.self)
            try await t.raw("UPDATE posts SET comment_count = comment_count + 1 WHERE id = \(uuid: postID)").run()
        }
        let author = try await personaAuthor(req.userID, mode: meta.mode, db)
        var answered: CommentObject.CommentAuthor? = nil
        if let answeredAuthorID { answered = try await personaAuthor(answeredAuthorID, mode: meta.mode, db) }
        let payload = CommentObject(id: created.id, content: created.content, created_at: created.created_at,
                                    parent_comment_id: created.parent_comment_id, like_count: created.like_count,
                                    is_liked: false, author: author,
                                    reply_to: answered.map { .init(id: $0.id, display_name: $0.display_name) },
                                    image_url: created.image_url, content_format: created.content_format)

        // Notify the post's author for any comment (grouped by post so several
        // collapse), plus the parent comment's author when this is a reply,
        // both delayed + cancel-if-deleted via SocialNotifyJob.
        NotifyService.dispatchSocial(req, .init(
            type: "post_commented", actorID: req.userID, recipientID: meta.authorID,
            postID: postID, commentID: created.id))
        // The person actually answered, for a flattened third-level reply
        // that's the reply it answers, not the comment it's stored under.
        if let placement, let answeredAuthorID, answeredAuthorID != meta.authorID {
            NotifyService.dispatchSocial(req, .init(
                type: "comment_replied", actorID: req.userID, recipientID: answeredAuthorID,
                postID: postID, commentID: created.id, parentCommentID: placement.replyToID))
        }
        await TranslationService.enqueue(req, .comment, id: created.id)
        await ModerationScan.enqueue(req, .comment, id: created.id)
        // TODO(phase 4): community_post_commented socket emit for open community viewers
        let res = try await DataResponse(data: payload).encodeResponse(for: req)
        res.status = .created
        return res
    }

    struct DeleteCommentResponse: Content { var status = "ok"; var removed: Int }
    static func deleteComment(_ req: Request) async throws -> DeleteCommentResponse {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        guard try await visibleMeta(postID, viewer: req.userID, officialReads: true, db) != nil else { throw InlineError(.notFound, "Post not found") }
        struct C: Decodable { let author_id: String }
        // `::text` matters: a raw `uuid` column decodes to Swift's uppercase
        // `UUID.uuidString` form, while `req.userID` is the lowercased JWT
        // subject, without the cast this comparison (and edit's below) can
        // never match, so delete/edit silently 403 for
        // everyone. Bug found and fixed alongside this batch's cascade change.
        guard let c = try await db.raw("SELECT author_id::text AS author_id FROM comments WHERE id = \(uuid: commentID) AND post_id = \(uuid: postID) AND status = 'posted'")
            .first(decoding: C.self) else { throw InlineError(.notFound, "Comment not found") }
        // Only the comment's author: a post's owner hides nothing by deleting
        // someone else's words. Undo is the author's alone, for a few seconds.
        guard c.author_id == req.userID else {
            throw InlineError(.forbidden, "Not allowed to delete this comment")
        }
        var removed = 0
        try await req.db.tx { t in
            struct D: Decodable { let id: String }
            // Cascade two levels: the comment itself, its direct replies, and
            // (only relevant when commentID is a root) those replies' own
            // replies, deleting a depth-1 reply already catches its depth-2
            // children via the middle clause; this extra clause is what's
            // needed for a root delete to also remove its grandchildren.
            let rows = try await t.raw("""
                UPDATE comments SET status = 'deleted', deleted_at = NOW()
                WHERE (id = \(uuid: commentID)
                    OR parent_comment_id = \(uuid: commentID)
                    OR parent_comment_id IN (SELECT id FROM comments WHERE parent_comment_id = \(uuid: commentID))
                ) AND status = 'posted'
                RETURNING id
                """).all(decoding: D.self)
            removed = rows.count
            try await t.raw("UPDATE posts SET comment_count = GREATEST(comment_count - \(bind: removed), 0) WHERE id = \(uuid: postID)").run()
        }
        return DeleteCommentResponse(removed: removed)
    }

    /// How long after deleting the author can still Undo: the app's toast
    /// shows for 5 seconds, plus room for a slow request. After that the
    /// comment is gone for good.
    static let undoWindow: TimeInterval = 10

    struct RestoreCommentResponse: Content { var restored: Int }

    /// `POST .../comments/:commentId/restore`: the author's Undo. Brings back
    /// exactly what that delete took (the comment and the replies that went
    /// with it, which share its `deleted_at`), never a moderator's removal.
    static func restoreComment(_ req: Request) async throws -> RestoreCommentResponse {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        guard try await visibleMeta(postID, viewer: req.userID, officialReads: true, db) != nil else { throw InlineError(.notFound, "Post not found") }
        struct C: Decodable { let author_id: String; let deleted_at: Date }
        guard let c = try await db.raw("""
            SELECT author_id::text AS author_id, deleted_at FROM comments
            WHERE id = \(uuid: commentID) AND post_id = \(uuid: postID) AND status = 'deleted' AND deleted_at IS NOT NULL
            """).first(decoding: C.self) else { throw InlineError(.notFound, "Comment not found") }
        guard c.author_id == req.userID else { throw InlineError(.forbidden, "Not allowed to restore this comment") }
        guard Date().timeIntervalSince(c.deleted_at) <= undoWindow else {
            throw InlineError(.gone, "This comment can't be restored anymore")
        }
        var restored = 0
        try await req.db.tx { t in
            struct D: Decodable { let id: String }
            restored = try await t.raw("""
                UPDATE comments SET status = 'posted', deleted_at = NULL
                WHERE (id = \(uuid: commentID)
                    OR parent_comment_id = \(uuid: commentID)
                    OR parent_comment_id IN (SELECT id FROM comments WHERE parent_comment_id = \(uuid: commentID))
                ) AND status = 'deleted'
                  AND deleted_at = (SELECT deleted_at FROM comments WHERE id = \(uuid: commentID))
                RETURNING id
                """).all(decoding: D.self).count
            try await t.raw("UPDATE posts SET comment_count = comment_count + \(bind: restored) WHERE id = \(uuid: postID)").run()
        }
        return RestoreCommentResponse(restored: restored)
    }

    struct EditCommentBody: Content { var content: String?; var content_format: String? }
    static func editComment(_ req: Request) async throws -> DataResponse<CommentObject> {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        let body = try req.content.decode(EditCommentBody.self)
        let content = body.content?.trimmedText ?? ""
        try validateCommentLength(content)
        // An edit is only refused for threats and slurs: asking "Are you sure?"
        // again would need a second prompt for little gain.
        try ModerationGate.check([content], .text)
        let newFormat: String? = PostStore.contentFormats.contains(body.content_format ?? "") ? body.content_format : nil
        guard let meta = try await visibleMeta(postID, viewer: req.userID, officialReads: true, db) else { throw InlineError(.notFound, "Post not found") }
        try req.requireNotBanned(in: meta.mode)
        struct C: Decodable { let author_id: String; let image_url: String? }
        guard let c = try await db.raw("""
            SELECT author_id::text AS author_id, image_url FROM comments
            WHERE id = \(uuid: commentID) AND post_id = \(uuid: postID) AND status = 'posted'
            """).first(decoding: C.self) else { throw InlineError(.notFound, "Comment not found") }
        guard c.author_id == req.userID else { throw InlineError(.forbidden, "Not allowed to edit this comment") }
        // Editing changes the text only; a comment with a photo may lose its text.
        guard !content.isEmpty || c.image_url != nil else { throw InlineError(.badRequest, "content is required") }
        // Keep the version being replaced; saving unchanged text isn't an edit.
        struct One: Decodable { let one: Int }
        let edited = try await db.raw("""
            INSERT INTO comment_revisions (comment_id, content, content_format, image_url)
            SELECT id, content, content_format, image_url FROM comments
            WHERE id = \(uuid: commentID)
              AND (COALESCE(content, '') IS DISTINCT FROM \(bind: content)
                OR content_format IS DISTINCT FROM COALESCE(\(bind: newFormat)::text, content_format))
            RETURNING 1 AS one
            """).first(decoding: One.self) != nil
        struct U: Decodable {
            let id: String; let content: String?; let created_at: Date; let parent_comment_id: String?
            let like_count: Int; let image_url: String?; let content_format: String?; let edited_at: Date?
        }
        let u = try await db.raw("""
            UPDATE comments SET content = \(bind: content), content_format = COALESCE(\(bind: newFormat)::text, content_format),
              edited_at = CASE WHEN \(bind: edited) THEN NOW() ELSE edited_at END
            WHERE id = \(uuid: commentID)
            RETURNING id, content, created_at, parent_comment_id, like_count, image_url, content_format, edited_at
            """).first(decoding: U.self)!
        struct L: Decodable { let is_liked: Bool }
        let liked = try await db.raw("SELECT EXISTS(SELECT 1 FROM comment_likes WHERE comment_id = \(uuid: commentID) AND user_id = \(uuid: req.userID)) AS is_liked")
            .first(decoding: L.self)!.is_liked
        let author = try await personaAuthor(req.userID, mode: meta.mode, db)
        await TranslationService.enqueue(req, .comment, id: u.id)
        await ModerationScan.enqueue(req, .comment, id: u.id)
        return DataResponse(data: CommentObject(id: u.id, content: u.content, created_at: u.created_at,
            parent_comment_id: u.parent_comment_id, like_count: u.like_count, is_liked: liked, author: author,
            image_url: u.image_url, content_format: u.content_format, edited_at: u.edited_at))
    }

    // MARK: comment edit history

    struct CommentRevision: Content {
        var id: String
        @NullCoded var content: String?
        var content_format: String
        @NullCoded var image_url: String?
        /// When this version was replaced by an edit.
        var created_at: Date
    }

    /// Earlier versions of a comment, newest first. Anyone who can read the
    /// comment can read its history (the same check as the comments list).
    static func commentHistory(_ req: Request) async throws -> DataResponse<[CommentRevision]> {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        guard let meta = try await visibleMeta(postID, viewer: req.userID, officialReads: true, db) else { throw InlineError(.notFound, "Post not found") }
        struct C: Decodable { let one: Int }
        guard try await db.raw("""
            SELECT 1 AS one FROM comments c
            WHERE c.id = \(uuid: commentID) AND c.post_id = \(uuid: postID) AND c.status = 'posted'
              AND \(AccountBans.visible(userRef: "c.author_id", mode: meta.mode, viewer: req.userID))
            """).first(decoding: C.self) != nil else { throw InlineError(.notFound, "Comment not found") }
        let rows = try await db.raw("""
            SELECT id::text AS id, content, COALESCE(content_format, 'plain') AS content_format, image_url, created_at
            FROM comment_revisions WHERE comment_id = \(uuid: commentID)
            ORDER BY created_at DESC LIMIT 50
            """).all(decoding: CommentRevision.self)
        return DataResponse(data: rows)
    }

    static func likeComment(_ req: Request) async throws -> LikeResponse {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        guard try await visibleMeta(postID, viewer: req.userID, officialReads: true, db) != nil else { throw InlineError(.notFound, "Post not found") }
        struct C: Decodable { let author_id: String }
        guard let comment = try await db.raw("SELECT author_id::text AS author_id FROM comments WHERE id = \(uuid: commentID) AND post_id = \(uuid: postID) AND status = 'posted'")
            .first(decoding: C.self) else { throw InlineError(.notFound, "Comment not found") }
        struct R: Decodable { let one: Int }
        let inserted = try await db.raw("INSERT INTO comment_likes (comment_id, user_id) VALUES (\(uuid: commentID), \(uuid: req.userID)) ON CONFLICT DO NOTHING RETURNING 1 AS one")
            .first(decoding: R.self)
        var liked = false
        if inserted != nil {
            try await db.raw("UPDATE comments SET like_count = like_count + 1 WHERE id = \(uuid: commentID)").run()
            liked = true
        } else {
            struct D: Decodable { let comment_id: String }
            let del = try await db.raw("DELETE FROM comment_likes WHERE comment_id = \(uuid: commentID) AND user_id = \(uuid: req.userID) RETURNING comment_id").all(decoding: D.self)
            if !del.isEmpty {
                try await db.raw("UPDATE comments SET like_count = GREATEST(like_count - 1, 0) WHERE id = \(uuid: commentID)").run()
            }
        }
        struct LC: Decodable { let like_count: Int }
        let lc = try await db.raw("SELECT like_count FROM comments WHERE id = \(uuid: commentID)").first(decoding: LC.self)!
        if liked {
            NotifyService.dispatchSocial(req, .init(
                type: "comment_liked", actorID: req.userID, recipientID: comment.author_id,
                postID: postID, commentID: commentID))
        }
        return LikeResponse(liked: liked, like_count: lc.like_count)
    }

    // MARK: hide / save

    struct HiddenResponse: Content { var status = "ok"; var hidden: Bool }
    struct SavedResponse: Content { var status = "ok"; var saved: Bool }

    static func hide(_ req: Request) async throws -> HiddenResponse {
        let postID = req.parameters.get("id")!
        guard try await visibleMeta(postID, viewer: req.userID, req.db.sql()) != nil else { throw InlineError(.notFound, "Post not found") }
        try await req.db.sql().raw("INSERT INTO hidden_posts (user_id, post_id) VALUES (\(uuid: req.userID), \(uuid: postID)) ON CONFLICT DO NOTHING").run()
        return HiddenResponse(hidden: true)
    }
    static func unhide(_ req: Request) async throws -> HiddenResponse {
        try await req.db.sql().raw("DELETE FROM hidden_posts WHERE user_id = \(uuid: req.userID) AND post_id = \(uuid: req.parameters.get("id")!)").run()
        return HiddenResponse(hidden: false)
    }
    // MARK: "Not interested" / "Show more like this" (migration 077)

    struct FeedbackBody: Content { var kind: String }
    struct FeedbackResponse: Content { @NullCoded var kind: String? }

    /// Tells the For you feed to show less (or more) like this post, and
    /// from its author, for the next 30 days. Not for your own posts.
    static func feedback(_ req: Request) async throws -> FeedbackResponse {
        let postID = req.parameters.get("id")!
        let b = try req.content.decode(FeedbackBody.self)
        guard FeedStore.feedbackKinds.contains(b.kind) else {
            throw Abort(.badRequest, reason: "kind must be less or more")
        }
        guard let meta = try await visibleMeta(postID, viewer: req.userID, req.db.sql()) else {
            throw InlineError(.notFound, "Post not found")
        }
        guard meta.authorID.caseInsensitiveCompare(req.userID) != .orderedSame else {
            throw Abort(.badRequest, reason: "That's your own post")
        }
        try await req.db.sql().raw("""
            INSERT INTO post_feedback (user_id, post_id, author_id, kind)
            VALUES (\(uuid: req.userID), \(uuid: postID), \(uuid: meta.authorID), \(bind: b.kind))
            ON CONFLICT (user_id, post_id) DO UPDATE SET kind = EXCLUDED.kind, created_at = NOW()
            """).run()
        return FeedbackResponse(kind: b.kind)
    }

    /// Takes it back (the toast's Undo).
    static func unfeedback(_ req: Request) async throws -> FeedbackResponse {
        guard UUID(uuidString: req.parameters.get("id")!) != nil else { throw InlineError(.notFound, "Post not found") }
        try await req.db.sql().raw("""
            DELETE FROM post_feedback WHERE user_id = \(uuid: req.userID) AND post_id = \(uuid: req.parameters.get("id")!)
            """).run()
        return FeedbackResponse(kind: nil)
    }

    static func save(_ req: Request) async throws -> SavedResponse {
        let postID = req.parameters.get("id")!
        let db = req.db.sql()
        guard let meta = try await visibleMeta(postID, viewer: req.userID, db) else { throw InlineError(.notFound, "Post not found") }
        // The official account visits communities without joining; saving
        // their posts isn't part of that.
        if let cid = meta.communityID, try await CommunityStore.membership(cid, req.userID, on: db) == nil {
            try await OfficialAccount.refuse(req.userID, "doesn't save community posts", on: db)
        }
        try await db.raw("INSERT INTO saved_posts (user_id, post_id) VALUES (\(uuid: req.userID), \(uuid: postID)) ON CONFLICT DO NOTHING").run()
        return SavedResponse(saved: true)
    }
    static func unsave(_ req: Request) async throws -> SavedResponse {
        try await req.db.sql().raw("DELETE FROM saved_posts WHERE user_id = \(uuid: req.userID) AND post_id = \(uuid: req.parameters.get("id")!)").run()
        return SavedResponse(saved: false)
    }
}

struct CommentObject: Content {
    var id: String
    @NullCoded var content: String?
    var created_at: Date
    @NullCoded var parent_comment_id: String?
    var like_count: Int
    var is_liked: Bool
    var author: CommentAuthor
    /// Who a reply is answering. The author of `reply_to_comment_id` (or of
    /// the parent, for replies written before that column). Null on top-level comments.
    @NullCoded var reply_to: ReplyTo? = nil
    /// Contains one of the viewer's muted words: still listed so threads keep
    /// their shape, but the app shows it collapsed.
    var muted: Bool = false
    /// en | vi | other | none, and the text in the other of en/vi (migration 048).
    @NullCoded var lang: String? = nil
    @NullCoded var translated_text: String? = nil
    /// The comment's photo, a bare /uploads/… path (migration 051).
    @NullCoded var image_url: String? = nil
    /// 'plain' or 'markdown' (migration 098).
    var content_format: String? = nil
    /// Last edit that changed the text (migration 110); null when never edited.
    @NullCoded var edited_at: Date? = nil
    struct ReplyTo: Content {
        var id: String
        var display_name: String
    }
    struct CommentAuthor: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_color: String?
        @NullCoded var avatar_url: String?
        var is_official: Bool? = nil
    }
}
struct CommentsListResponse: Content { var data: [CommentObject]; var total: Int }
