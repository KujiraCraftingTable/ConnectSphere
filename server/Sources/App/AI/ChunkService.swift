import Vapor
import SQLKit

/// The chunk-based embedding
/// pipeline. One `user_embedding_chunks` row per embeddable unit:
///   • `user_profile` (source_id NULL): normalised profile fields
///   • `post` (source_id = posts.id): one post's content + article title + tags
///
/// Each chunk stores `source_hash`, the fingerprint of the text it was built
/// from (`post_embed_source_hash` / `profile_embed_source_hash`, migration 033).
/// A build whose source hasn't changed is skipped before any LLM call, so
/// duplicate jobs from edits and the sweep cost nothing.
enum ChunkService {
    static let modelName = "mxbai-embed-large"

    private struct Hash: Decodable { let h: String? }
    private struct Stored: Decodable { let source_hash: String? }

    static func postSourceHash(_ postID: String, on db: any SQLDatabase) async throws -> String? {
        try await db.raw("SELECT post_embed_source_hash(\(uuid: postID)) AS h").first(decoding: Hash.self)?.h
    }

    static func profileSourceHash(_ userID: String, on db: any SQLDatabase) async throws -> String? {
        try await db.raw("SELECT profile_embed_source_hash(\(uuid: userID)) AS h").first(decoding: Hash.self)?.h
    }

    /// Attach the canonical name when the term is a known alias (Tier-1 exact, pure SQL).
    static func canonicalizeTerm(_ cfg: OllamaService.Config, _ term: String, on db: any SQLDatabase) async -> String {
        if let e = try? await SearchStore.exactMatch(term, category: nil, on: db),
           e.canonical_name.trimmingCharacters(in: .whitespaces).lowercased() != term.trimmingCharacters(in: .whitespaces).lowercased() {
            return "\(term) (\(e.canonical_name))"
        }
        return term
    }
    static func canonicalizeAll(_ cfg: OllamaService.Config, _ terms: [String], on db: any SQLDatabase) async -> [String] {
        var out: [String] = []
        for t in terms { out.append(await canonicalizeTerm(cfg, t, on: db)) }
        return out
    }

    /// Embed `content` and upsert one chunk row. `sourceID == nil` = profile chunk.
    @discardableResult
    static func upsertChunk(userID: String, sourceType: String, sourceID: String?, chunkIndex: Int = 0,
                            topic: String?, content: String, sourceHash: String?, cfg: OllamaService.Config,
                            on db: any SQLDatabase, logger: Logger) async -> Bool {
        guard let embedding = await OllamaService.embedText(cfg, content, logger: logger) else {
            logger.warning("chunkService: embed failed (\(sourceType) \(sourceID ?? "profile"))")
            return false
        }
        let vec = SearchStore.vecLiteral(embedding)
        do {
            if sourceID == nil {
                try await db.raw("""
                    INSERT INTO user_embedding_chunks
                      (user_id, source_type, source_id, chunk_index, topic, content, embedding, model_name, source_hash)
                    VALUES (\(uuid: userID), \(bind: sourceType), NULL, \(bind: chunkIndex), \(bind: topic),
                            \(bind: content), \(bind: vec)::vector, \(bind: modelName), \(bind: sourceHash))
                    ON CONFLICT (user_id, source_type, chunk_index) WHERE source_id IS NULL
                    DO UPDATE SET topic = EXCLUDED.topic, content = EXCLUDED.content,
                                  embedding = EXCLUDED.embedding, model_name = EXCLUDED.model_name,
                                  source_hash = EXCLUDED.source_hash
                    """).run()
            } else {
                try await db.raw("""
                    INSERT INTO user_embedding_chunks
                      (user_id, source_type, source_id, chunk_index, topic, content, embedding, model_name, source_hash)
                    VALUES (\(uuid: userID), \(bind: sourceType), \(uuid: sourceID), \(bind: chunkIndex), \(bind: topic),
                            \(bind: content), \(bind: vec)::vector, \(bind: modelName), \(bind: sourceHash))
                    ON CONFLICT (user_id, source_type, source_id, chunk_index) WHERE source_id IS NOT NULL
                    DO UPDATE SET topic = EXCLUDED.topic, content = EXCLUDED.content,
                                  embedding = EXCLUDED.embedding, model_name = EXCLUDED.model_name,
                                  source_hash = EXCLUDED.source_hash
                    """).run()
            }
            let backlogID = sourceID ?? userID
            try? await db.raw("""
                DELETE FROM embedding_backlog WHERE source_type = \(bind: sourceType) AND source_id = \(uuid: backlogID)
                """).run()
            return true
        } catch {
            logger.warning("chunkService: upsert failed: \(error)")
            return false
        }
    }

    // MARK: profile chunk

    @discardableResult
    static func buildProfileChunk(_ userID: String, cfg: OllamaService.Config, on db: any SQLDatabase, logger: Logger) async throws -> Bool {
        guard let hash = try await profileSourceHash(userID, on: db) else {
            try await db.raw("DELETE FROM user_embedding_chunks WHERE user_id = \(uuid: userID) AND source_type = 'user_profile'").run()
            return false
        }
        let stored = try await db.raw("""
            SELECT source_hash FROM user_embedding_chunks
            WHERE user_id = \(uuid: userID) AND source_type = 'user_profile' AND source_id IS NULL AND chunk_index = 0
            """).first(decoding: Stored.self)
        if stored?.source_hash == hash { return true }

        struct P: Decodable {
            let hobby_bio: String?; let work_bio: String?; let job_title: String?
            let company: String?; let location: String?; let interests: String; let skills: String
        }
        guard let p = try await db.raw("""
            SELECT u.hobby_bio, u.work_bio, u.job_title, u.company, u.location,
              COALESCE(json_agg(DISTINCT ui.interest) FILTER (WHERE ui.interest IS NOT NULL), '[]')::text AS interests,
              COALESCE(json_agg(DISTINCT us.skill) FILTER (WHERE us.skill IS NOT NULL), '[]')::text AS skills
            FROM users u
            LEFT JOIN user_interests ui ON ui.user_id = u.id
            LEFT JOIN user_skills us ON us.user_id = u.id
            WHERE u.id = \(uuid: userID) GROUP BY u.id
            """).first(decoding: P.self) else { return false }

        let dec = JSONDecoder()
        let rawInterests = (try? dec.decode([String].self, from: Data(p.interests.utf8))) ?? []
        let rawSkills = (try? dec.decode([String].self, from: Data(p.skills.utf8))) ?? []

        let interests = await canonicalizeAll(cfg, rawInterests, on: db)
        let skills = await canonicalizeAll(cfg, rawSkills, on: db)
        let hobbyBioEn = try await translateOrNil(cfg, p.hobby_bio)
        let workBioEn = try await translateOrNil(cfg, p.work_bio)

        var parts: [String] = []
        if !interests.isEmpty { parts.append("Interests: \(interests.joined(separator: ", "))") }
        if !skills.isEmpty { parts.append("Skills: \(skills.joined(separator: ", "))") }
        if let b = hobbyBioEn { parts.append("Bio: \(b)") }
        if let w = workBioEn, w != hobbyBioEn { parts.append("Work bio: \(w)") }
        if let j = p.job_title { parts.append("Job: \(j)") }
        if let c = p.company { parts.append("Company: \(c)") }
        if let l = p.location { parts.append("Location: \(l)") }
        // Work history: each role as "title at company", current first.
        struct R: Decodable { let title: String; let company: String }
        let roles = try await db.raw("""
            SELECT e.title, COALESCE(c.name, e.company_name) AS company
            FROM work_experiences e LEFT JOIN companies c ON c.id = e.company_id
            WHERE e.user_id = \(uuid: userID)
            ORDER BY (e.end_month IS NULL) DESC, e.start_month DESC LIMIT 10
            """).all(decoding: R.self)
        if !roles.isEmpty { parts.append("Experience: " + roles.map { "\($0.title) at \($0.company)" }.joined(separator: "; ")) }

        let content = parts.joined(separator: "\n")
        if content.isEmpty {
            try await db.raw("DELETE FROM user_embedding_chunks WHERE user_id = \(uuid: userID) AND source_type = 'user_profile'").run()
            return false
        }
        return await upsertChunk(userID: userID, sourceType: "user_profile", sourceID: nil, topic: nil,
                                 content: content, sourceHash: hash, cfg: cfg, on: db, logger: logger)
    }

    // MARK: post chunk

    @discardableResult
    static func buildPostChunk(_ postID: String, cfg: OllamaService.Config, on db: any SQLDatabase, logger: Logger) async throws -> Bool {
        guard let hash = try await postSourceHash(postID, on: db) else {
            try await deletePostChunks(postID, on: db)
            return false
        }
        let stored = try await db.raw("""
            SELECT source_hash FROM user_embedding_chunks
            WHERE source_type = 'post' AND source_id = \(uuid: postID) AND chunk_index = 0
            """).first(decoding: Stored.self)
        if stored?.source_hash == hash { return true }

        struct R: Decodable {
            let author_id: String; let content: String?; let content_format: String?; let article_title: String?
            let status: String; let tags: String; let post_type: String
        }
        guard let post = try await db.raw("""
            SELECT p.author_id::text AS author_id, p.content, p.content_format, p.article_title, p.status, p.post_type,
              COALESCE(array_to_json(array_agg(pt.tag) FILTER (WHERE pt.tag IS NOT NULL)), '[]')::text AS tags
            FROM posts p
            LEFT JOIN post_tags pt ON pt.post_id = p.id
            WHERE p.id = \(uuid: postID) GROUP BY p.id
            """).first(decoding: R.self) else {
            try await db.raw("DELETE FROM user_embedding_chunks WHERE source_type = 'post' AND source_id = \(uuid: postID)").run()
            return false
        }
        // A check-legit post stays out of search: it's only on the seller's Marketplace page.
        if post.status != "posted" || post.post_type == "legit" {
            try await db.raw("DELETE FROM user_embedding_chunks WHERE source_type = 'post' AND source_id = \(uuid: postID)").run()
            return false
        }
        let tags = (try? JSONDecoder().decode([String].self, from: Data(post.tags.utf8))) ?? []
        // The embedding should see the words, not `**` or `[label](url)`.
        let words = post.content_format == "markdown" ? post.content.map(MarkdownText.plain) : post.content
        let naturalText = [words, post.article_title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
        let contentEn = try await translateOrNil(cfg, naturalText.isEmpty ? nil : naturalText)
        let canonTags = await canonicalizeAll(cfg, tags, on: db)

        var parts: [String] = []
        if let c = contentEn { parts.append("Content: \(c)") }
        if !canonTags.isEmpty { parts.append("Topics: \(canonTags.joined(separator: ", "))") }
        // A job: what it is, where, at what level, and the skills it needs.
        struct J: Decodable { let title: String; let company: String?; let level: String?; let location: String?; let work_format: String?; let skills: String }
        if let job = try await db.raw("""
            SELECT jp.title, COALESCE(c.name, jp.company) AS company, jp.level, jp.location, jp.work_format,
              COALESCE((SELECT string_agg(js.skill, ', ' ORDER BY js.skill) FROM job_skills js WHERE js.job_id = jp.id), '') AS skills
            FROM job_posts jp LEFT JOIN companies c ON c.id = jp.company_id WHERE jp.post_id = \(uuid: postID)
            """).first(decoding: J.self) {
            parts.append("Job: \(job.title)" + (job.company.map { " at \($0)" } ?? ""))
            let facts = [job.level, job.location, job.work_format].compactMap { $0 }
            if !facts.isEmpty { parts.append("Details: " + facts.joined(separator: ", ")) }
            if !job.skills.isEmpty { parts.append("Skills: \(job.skills)") }
        }
        let content = parts.joined(separator: "\n")
        if content.isEmpty { return false }

        return await upsertChunk(userID: post.author_id, sourceType: "post", sourceID: postID,
                                 topic: tags.first, content: content, sourceHash: hash, cfg: cfg, on: db, logger: logger)
    }

    static func deletePostChunks(_ postID: String, on db: any SQLDatabase) async throws {
        try await db.raw("DELETE FROM user_embedding_chunks WHERE source_type = 'post' AND source_id = \(uuid: postID)").run()
    }

    private static func translateOrNil(_ cfg: OllamaService.Config, _ text: String?) async throws -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        let out = try await OllamaService.translateToEnglish(cfg, t)
        return out.isEmpty ? nil : out
    }
}
