import Vapor

/// Port of `backend/src/services/postAnalyzeService.js` — classify a post as
/// hobby / work / neutral. Keyword fast-path first (no LLM), then a constrained
/// LLM call, then a neutral fallback on any failure.
enum PostAnalyzeService {
    struct Result: Content {
        var suggestedMode: String
        var confidence: Double
        var reason: String
        /// Node's keyword fast-path spreads `fast: true` into the response; the
        /// LLM path has no such key.
        var fast: Bool?
    }

    static let colleagueKeywords = [
        "sprint", "deadline", "deploy", "merge", "pull request", "code review",
        "meeting", "standup", "roadmap", "milestone", "backlog", "jira",
        "project", "stakeholder", "client", "presentation", "kpi", "okr",
        "hiring", "interview", "onboard", "promotion", "salary", "offer letter",
        "startup", "funding", "investor", "pitch", "revenue", "quarterly",
        "công ty", "dự án", "sếp", "đồng nghiệp", "hợp đồng", "lương",
        "tuyển dụng", "phỏng vấn", "thăng chức", "báo cáo",
    ]
    static let friendKeywords = [
        "cafe", "cà phê", "trà sữa", "anime", "manga", "phim", "nhạc", "concert",
        "du lịch", "travel", "ăn uống", "bạn bè", "weekend", "cuối tuần",
        "gaming", "game", "stream", "tiktok", "instagram", "gym", "workout",
        "hẹn hò", "date", "crush", "người yêu", "birthday", "sinh nhật",
        "mệt mỏi", "vui", "buồn", "nhớ", "chill", "relax",
    ]

    static let systemPrompt = """
        You analyze social media post content and classify it as "hobby" (personal/entertainment/lifestyle/hobbies) or "work" (professional/work/career/skills/business) or "neutral".

        Reply ONLY with JSON, no explanation outside JSON.

        Schema: {"suggestedMode": "hobby|work|neutral", "confidence": 0.0-1.0, "reason": "one short sentence in Vietnamese"}

        Examples:
        "Hôm nay đi cafe với bạn, uống trà sữa ngon lắm ☕" → {"suggestedMode":"hobby","confidence":0.95,"reason":"Nội dung cá nhân về giải trí"}
        "Vừa ra mắt tính năng mới cho dự án, team làm việc rất hiệu quả!" → {"suggestedMode":"work","confidence":0.92,"reason":"Nội dung liên quan đến công việc"}
        "Trời hôm nay đẹp quá" → {"suggestedMode":"neutral","confidence":0.8,"reason":"Không rõ ngữ cảnh"}
        """

    static func keywordCheck(_ content: String) -> Result? {
        let lower = content.lowercased()
        let workScore = colleagueKeywords.filter { lower.contains($0) }.count
        let hobbyScore = friendKeywords.filter { lower.contains($0) }.count
        if workScore >= 2, workScore > hobbyScore * 2 {
            return Result(suggestedMode: "work", confidence: 0.85, reason: "Nội dung liên quan đến công việc", fast: true)
        }
        if hobbyScore >= 2, hobbyScore > workScore * 2 {
            return Result(suggestedMode: "hobby", confidence: 0.85, reason: "Nội dung mang tính cá nhân/giải trí", fast: true)
        }
        return nil
    }

    static func analyze(_ cfg: OllamaService.Config, _ content: String, logger: Logger) async -> Result {
        if let fast = keywordCheck(content) { return fast }
        do {
            let j = try await OllamaService.rawChatObject(cfg, system: systemPrompt, user: content, temperature: 0.1)
            let mode = j["suggestedMode"] as? String ?? "neutral"
            let conf: Double
            if let d = j["confidence"] as? Double { conf = min(1, max(0, d)) }
            else if let i = j["confidence"] as? Int { conf = min(1, max(0, Double(i))) }
            else { conf = 0.5 }
            return Result(
                suggestedMode: ["hobby", "work", "neutral"].contains(mode) ? mode : "neutral",
                confidence: conf,
                reason: j["reason"] as? String ?? "")
        } catch {
            logger.warning("Post analyze failed — returning neutral: \(error)")
            return Result(suggestedMode: "neutral", confidence: 0, reason: "")
        }
    }
}
