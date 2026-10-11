import Vapor
import SQLKit

/// Port of `backend/src/routes/interactionRoutes.js` — mounted under
/// `/api/posts/:id` (mergeParams). Notification/socket side effects deferred to
/// Phase 3/4. Inline `{error}` bodies match the Node handlers. Includes the
/// review fix: comment restore is wrapped in a txn with a `status = 'deleted'`
/// guard and a 409 on a double restore.
struct InteractionsController {
    static func register(routes: any RoutesBuilder) {
        routes.post("like", use: likePost)
        routes.get("comments", use: listComments)
        routes.post("comments", use: addComment)
        routes.delete("comments", ":commentId", use: deleteComment)
        routes.patch("comments", ":commentId", use: editComment)
        routes.post("comments", ":commentId", "restore", use: restoreComment)
        routes.post("comments", ":commentId", "like", use: likeComment)
        routes.on(.POST, "hide", use: hide); routes.on(.DELETE, "hide", use: unhide)
        routes.on(.POST, "save", use: save); routes.on(.DELETE, "save", use: unsave)
    }

    struct VisibleMeta { let id: String; let authorID: String; let mode: String; let communityID: String? }

    static func visibleMeta(_ postID: String, viewer: String, _ db: any SQLDatabase) async throws -> VisibleMeta? {
        guard let post = try await PostStore.findById(postID, viewer: viewer, on: db) else { return nil }
        let meta = try await PostStore.findMeta(postID, on: db)
        return VisibleMeta(id: post.id, authorID: post.author.id, mode: post.mode, communityID: meta?.community_id)
    }

    static func personaAuthor(_ userID: String, mode: String, _ db: any SQLDatabase) async throws -> CommentObject.CommentAuthor {
        struct A: Decodable { let id: String; let display_name: String; let avatar_color: String?; let avatar_url: String? }
        let a = try await db.raw("""
            SELECT id,
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
        guard let meta = try await visibleMeta(postID, viewer: req.userID, db) else {
            throw InlineError(.notFound, "Post not found")
        }
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

    // MARK: comments list / add / delete / edit / restore / like

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
        let offset = max((try? req.query.get(Int.self, at: "offset")) ?? 0, 0)
        guard try await visibleMeta(postID, viewer: req.userID, db) != nil else {
            throw InlineError(.notFound, "Post not found")
        }
        struct Row: Decodable {
            let id: String; let content: String?; let created_at: Date
            let parent_comment_id: String?; let like_count: Int; let is_liked: Bool; let author: String
            let reply_to: String?; let muted: Bool
        }
        let rows = try await db.raw("""
            SELECT c.id, c.content, c.created_at, c.parent_comment_id, c.like_count,
              EXISTS(SELECT 1 FROM comment_likes cl WHERE cl.comment_id = c.id AND cl.user_id = \(uuid: req.userID)) AS is_liked,
              json_build_object('id', u.id, 'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "p.mode")),
                'avatar_color', u.avatar_color, 'avatar_url', \(unsafeRaw: PersonaSQL.expr("avatar_url", modeRef: "p.mode")))::text AS author,
              CASE WHEN rc.id IS NULL THEN NULL ELSE json_build_object('id', ru.id,
                'display_name', \(unsafeRaw: PersonaSQL.expr("display_name", modeRef: "p.mode", alias: "ru")))::text END AS reply_to,
              (c.author_id <> \(uuid: req.userID) AND \(PostStore.mutedWordHit(req.userID, textSQL: "c.content", modeRef: "p.mode"))) AS muted
            FROM comments c JOIN posts p ON p.id = c.post_id JOIN users u ON u.id = c.author_id
            LEFT JOIN comments rc ON rc.id = COALESCE(c.reply_to_comment_id, c.parent_comment_id)
            LEFT JOIN users ru ON ru.id = rc.author_id
            WHERE c.post_id = \(uuid: postID) AND c.status = 'posted'
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
                          muted: r.muted)
        }
        return CommentsListResponse(data: comments, total: total)
    }

    struct AddCommentBody: Content { var content: String?; var parent_comment_id: String? }

    static func addComment(_ req: Request) async throws -> Response {
        let postID = req.parameters.get("id")!
        let db = req.db.sql()
        let b = try req.content.decode(AddCommentBody.self)
        guard let content = b.content?.trimmingCharacters(in: .whitespaces), !content.isEmpty else {
            throw InlineError(.badRequest, "content is required")
        }
        guard let meta = try await visibleMeta(postID, viewer: req.userID, db) else {
            throw InlineError(.notFound, "Post not found")
        }
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
        struct C: Decodable { let id: String; let content: String?; let created_at: Date; let parent_comment_id: String?; let like_count: Int }
        var created: C!
        try await req.db.tx { t in
            created = try await t.raw("""
                INSERT INTO comments (post_id, author_id, content, parent_comment_id, reply_to_comment_id)
                VALUES (\(uuid: postID), \(uuid: req.userID), \(bind: content), \(uuid: placement?.parentID), \(uuid: placement?.replyToID))
                RETURNING id, content, created_at, parent_comment_id, like_count
                """).first(decoding: C.self)
            try await t.raw("UPDATE posts SET comment_count = comment_count + 1 WHERE id = \(uuid: postID)").run()
        }
        let author = try await personaAuthor(req.userID, mode: meta.mode, db)
        var answered: CommentObject.CommentAuthor? = nil
        if let answeredAuthorID { answered = try await personaAuthor(answeredAuthorID, mode: meta.mode, db) }
        let payload = CommentObject(id: created.id, content: created.content, created_at: created.created_at,
                                    parent_comment_id: created.parent_comment_id, like_count: created.like_count,
                                    is_liked: false, author: author,
                                    reply_to: answered.map { .init(id: $0.id, display_name: $0.display_name) })

        // Notify the post's author for any comment (grouped by post so several
        // collapse), plus the parent comment's author when this is a reply —
        // both delayed + cancel-if-deleted via SocialNotifyJob.
        NotifyService.dispatchSocial(req, .init(
            type: "post_commented", actorID: req.userID, recipientID: meta.authorID,
            postID: postID, commentID: created.id))
        // The person actually answered — for a flattened third-level reply
        // that's the reply it answers, not the comment it's stored under.
        if let placement, let answeredAuthorID, answeredAuthorID != meta.authorID {
            NotifyService.dispatchSocial(req, .init(
                type: "comment_replied", actorID: req.userID, recipientID: answeredAuthorID,
                postID: postID, commentID: created.id, parentCommentID: placement.replyToID))
        }
        // TODO(phase 4): community_post_commented socket emit for open community viewers
        let res = try await DataResponse(data: payload).encodeResponse(for: req)
        res.status = .created
        return res
    }

    struct DeleteCommentResponse: Content { var status = "ok"; var removed: Int }
    static func deleteComment(_ req: Request) async throws -> DeleteCommentResponse {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        guard let meta = try await visibleMeta(postID, viewer: req.userID, db) else { throw InlineError(.notFound, "Post not found") }
        struct C: Decodable { let author_id: String }
        // `::text` matters: a raw `uuid` column decodes to Swift's uppercase
        // `UUID.uuidString` form, while `req.userID` is the lowercased JWT
        // subject — without the cast this comparison (and edit's/restore's
        // below) can never match, so delete/edit/restore silently 403 for
        // everyone. Bug found and fixed alongside this batch's cascade change.
        guard let c = try await db.raw("SELECT author_id::text AS author_id FROM comments WHERE id = \(uuid: commentID) AND post_id = \(uuid: postID) AND status = 'posted'")
            .first(decoding: C.self) else { throw InlineError(.notFound, "Comment not found") }
        guard c.author_id == req.userID || meta.authorID == req.userID else {
            throw InlineError(.forbidden, "Not allowed to delete this comment")
        }
        var removed = 0
        try await req.db.tx { t in
            struct D: Decodable { let id: String }
            // Cascade two levels: the comment itself, its direct replies, and
            // (only relevant when commentID is a root) those replies' own
            // replies — deleting a depth-1 reply already catches its depth-2
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

    struct EditCommentBody: Content { var content: String? }
    static func editComment(_ req: Request) async throws -> DataResponse<CommentObject> {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        guard let content = try req.content.decode(EditCommentBody.self).content?.trimmingCharacters(in: .whitespaces), !content.isEmpty else {
            throw InlineError(.badRequest, "content is required")
        }
        guard let meta = try await visibleMeta(postID, viewer: req.userID, db) else { throw InlineError(.notFound, "Post not found") }
        struct C: Decodable { let author_id: String }
        guard let c = try await db.raw("SELECT author_id::text AS author_id FROM comments WHERE id = \(uuid: commentID) AND post_id = \(uuid: postID) AND status = 'posted'")
            .first(decoding: C.self) else { throw InlineError(.notFound, "Comment not found") }
        guard c.author_id == req.userID else { throw InlineError(.forbidden, "Not allowed to edit this comment") }
        struct U: Decodable { let id: String; let content: String?; let created_at: Date; let parent_comment_id: String?; let like_count: Int }
        let u = try await db.raw("""
            UPDATE comments SET content = \(bind: content) WHERE id = \(uuid: commentID)
            RETURNING id, content, created_at, parent_comment_id, like_count
            """).first(decoding: U.self)!
        struct L: Decodable { let is_liked: Bool }
        let liked = try await db.raw("SELECT EXISTS(SELECT 1 FROM comment_likes WHERE comment_id = \(uuid: commentID) AND user_id = \(uuid: req.userID)) AS is_liked")
            .first(decoding: L.self)!.is_liked
        let author = try await personaAuthor(req.userID, mode: meta.mode, db)
        return DataResponse(data: CommentObject(id: u.id, content: u.content, created_at: u.created_at,
            parent_comment_id: u.parent_comment_id, like_count: u.like_count, is_liked: liked, author: author))
    }

    static func restoreComment(_ req: Request) async throws -> RestoreCommentResponse {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        guard let meta = try await visibleMeta(postID, viewer: req.userID, db) else { throw InlineError(.notFound, "Post not found") }
        struct C: Decodable { let author_id: String }
        guard let c = try await db.raw("SELECT author_id::text AS author_id FROM comments WHERE id = \(uuid: commentID) AND post_id = \(uuid: postID) AND status = 'deleted'")
            .first(decoding: C.self) else { throw InlineError(.notFound, "Comment not found or not deleted") }
        guard c.author_id == req.userID else { throw InlineError(.forbidden, "Not allowed to restore this comment") }
        struct R: Decodable { let id: String; let content: String?; let created_at: Date; let parent_comment_id: String?; let like_count: Int }
        var restored: R?
        var commentCount = 0
        try await req.db.tx { t in
            restored = try await t.raw("""
                UPDATE comments SET status = 'posted', deleted_at = NULL
                WHERE id = \(uuid: commentID) AND status = 'deleted'
                RETURNING id, content, created_at, parent_comment_id, like_count
                """).first(decoding: R.self)
            guard restored != nil else { return }
            struct CC: Decodable { let comment_count: Int }
            commentCount = try await t.raw("UPDATE posts SET comment_count = comment_count + 1 WHERE id = \(uuid: postID) RETURNING comment_count")
                .first(decoding: CC.self)!.comment_count
        }
        guard let r = restored else { throw InlineError(.conflict, "Comment is not currently deleted") }
        let author = try await personaAuthor(req.userID, mode: meta.mode, db)
        return RestoreCommentResponse(
            data: CommentObject(id: r.id, content: r.content, created_at: r.created_at,
                parent_comment_id: r.parent_comment_id, like_count: r.like_count, is_liked: false, author: author),
            comment_count: commentCount)
    }

    static func likeComment(_ req: Request) async throws -> LikeResponse {
        let postID = req.parameters.get("id")!, commentID = req.parameters.get("commentId")!
        let db = req.db.sql()
        guard try await visibleMeta(postID, viewer: req.userID, db) != nil else { throw InlineError(.notFound, "Post not found") }
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
    static func save(_ req: Request) async throws -> SavedResponse {
        let postID = req.parameters.get("id")!
        guard try await visibleMeta(postID, viewer: req.userID, req.db.sql()) != nil else { throw InlineError(.notFound, "Post not found") }
        try await req.db.sql().raw("INSERT INTO saved_posts (user_id, post_id) VALUES (\(uuid: req.userID), \(uuid: postID)) ON CONFLICT DO NOTHING").run()
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
    /// Who a reply is answering — the author of `reply_to_comment_id` (or of
    /// the parent, for replies written before that column). Null on top-level comments.
    @NullCoded var reply_to: ReplyTo? = nil
    /// Contains one of the viewer's muted words: still listed so threads keep
    /// their shape, but the app shows it collapsed.
    var muted: Bool = false
    struct ReplyTo: Content {
        var id: String
        var display_name: String
    }
    struct CommentAuthor: Content {
        var id: String
        var display_name: String
        @NullCoded var avatar_color: String?
        @NullCoded var avatar_url: String?
    }
}
struct CommentsListResponse: Content { var data: [CommentObject]; var total: Int }
struct RestoreCommentResponse: Content { var data: CommentObject; var comment_count: Int }
