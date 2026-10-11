import Vapor

/// What happens when a post goes live — at once, or later from a draft or a
/// schedule. Kept in one place so a scheduled post gets exactly what an
/// immediate one does.
enum PostPublisher {
    /// For feed posts (community posts don't have these yet): the AI mode
    /// check, which notifies the author on a mismatch, and tag extraction →
    /// embedding (or a direct embed for a link/image-only post) — the queue
    /// part only when this server owns the job schedule.
    static func afterPublish(_ req: Request, post: PostObject) async {
        let postID = post.id, postMode = post.mode, postText = post.content ?? "", authorID = req.userID
        if !postText.isEmpty {
            let cfg = req.ollama
            NotifyService.fireAndForget(req) { d, h, l in
                let r = await PostAnalyzeService.analyze(cfg, postText, logger: l)
                if r.confidence >= 0.75, r.suggestedMode != "neutral", r.suggestedMode != postMode {
                    _ = await NotifyService.pushUserNotification(userID: authorID, type: "mode_mismatch",
                        postID: postID,
                        payload: ["suggestedMode": r.suggestedMode, "currentMode": postMode, "reason": r.reason],
                        on: d, hub: h, logger: l)
                }
            }
        }
        if BackgroundJobs.enabled {
            if !postText.isEmpty {
                try? await req.queue.dispatch(BackgroundJobs.TagExtractionJob.self,
                    .init(postId: postID, content: postText), maxRetryCount: 3)
            } else {
                try? await req.queue.dispatch(BackgroundJobs.ChunkEmbedJob.self,
                    .init(kind: .post, id: postID), maxRetryCount: 3)
            }
        }
    }
}
