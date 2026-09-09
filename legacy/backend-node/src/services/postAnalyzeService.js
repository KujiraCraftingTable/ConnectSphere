/**
 * postAnalyzeService.js
 *
 * Uses an LLM to analyze post content:
 * → returns { suggestedMode: "hobby" | "work" | "neutral", confidence, reason }
 */

const { ollama } = require('../config/env');
const logger = require('../utils/logger');

// ── Keyword fast-path (no LLM needed) ─────────────────────────────────────────

const COLLEAGUE_KEYWORDS = [
  'sprint', 'deadline', 'deploy', 'merge', 'pull request', 'code review',
  'meeting', 'standup', 'roadmap', 'milestone', 'backlog', 'jira',
  'project', 'stakeholder', 'client', 'presentation', 'kpi', 'okr',
  'hiring', 'interview', 'onboard', 'promotion', 'salary', 'offer letter',
  'startup', 'funding', 'investor', 'pitch', 'revenue', 'quarterly',
  'công ty', 'dự án', 'sếp', 'đồng nghiệp', 'hợp đồng', 'lương',
  'tuyển dụng', 'phỏng vấn', 'thăng chức', 'báo cáo',
];

const FRIEND_KEYWORDS = [
  'cafe', 'cà phê', 'trà sữa', 'anime', 'manga', 'phim', 'nhạc', 'concert',
  'du lịch', 'travel', 'ăn uống', 'bạn bè', 'weekend', 'cuối tuần',
  'gaming', 'game', 'stream', 'tiktok', 'instagram', 'gym', 'workout',
  'hẹn hò', 'date', 'crush', 'người yêu', 'birthday', 'sinh nhật',
  'mệt mỏi', 'vui', 'buồn', 'nhớ', 'chill', 'relax',
];

function keywordCheck(content) {
  const lower = content.toLowerCase();

  let workScore = 0;
  let hobbyScore    = 0;

  for (const kw of COLLEAGUE_KEYWORDS) {
    if (lower.includes(kw)) workScore++;
  }
  for (const kw of FRIEND_KEYWORDS) {
    if (lower.includes(kw)) hobbyScore++;
  }

  // Only conclude when there's a clear enough gap
  if (workScore >= 2 && workScore > hobbyScore * 2) {
    return { suggestedMode: 'work', confidence: 0.85, reason: 'Nội dung liên quan đến công việc', fast: true };
  }
  if (hobbyScore >= 2 && hobbyScore > workScore * 2) {
    return { suggestedMode: 'hobby', confidence: 0.85, reason: 'Nội dung mang tính cá nhân/giải trí', fast: true };
  }

  return null; // unclear → call the LLM
}

const SYSTEM_PROMPT = `You analyze social media post content and classify it as "hobby" (personal/entertainment/lifestyle/hobbies) or "work" (professional/work/career/skills/business) or "neutral".

Reply ONLY with JSON, no explanation outside JSON.

Schema: {"suggestedMode": "hobby|work|neutral", "confidence": 0.0-1.0, "reason": "one short sentence in Vietnamese"}

Examples:
"Hôm nay đi cafe với bạn, uống trà sữa ngon lắm ☕" → {"suggestedMode":"hobby","confidence":0.95,"reason":"Nội dung cá nhân về giải trí"}
"Vừa ra mắt tính năng mới cho dự án, team làm việc rất hiệu quả!" → {"suggestedMode":"work","confidence":0.92,"reason":"Nội dung liên quan đến công việc"}
"Trời hôm nay đẹp quá" → {"suggestedMode":"neutral","confidence":0.8,"reason":"Không rõ ngữ cảnh"}`;

async function analyzePostContent(content) {
  // Fast-path: keyword check first, no need to call the LLM
  const fast = keywordCheck(content);
  if (fast) {
    logger.debug({ fast }, 'Post analyze: keyword fast-path');
    return fast;
  }

  try {
    const body = {
      model: ollama.model,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user',   content: content },
      ],
      options: { temperature: 0.1 },
      stream: false,
    };

    const response = await fetch(`${ollama.url}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });

    if (!response.ok) throw new Error(`LLM error: ${response.status}`);

    const data = await response.json();
    const raw  = data.message?.content ?? '';

    // Strip markdown fences
    const cleaned = raw
      .replace(/```json\s*/gi, '')
      .replace(/```\s*/g, '')
      .trim();

    const start = cleaned.indexOf('{');
    const end   = cleaned.lastIndexOf('}');
    if (start === -1 || end === -1) throw new Error('No JSON in LLM response');

    const result = JSON.parse(cleaned.slice(start, end + 1));

    return {
      suggestedMode: ['hobby', 'work', 'neutral'].includes(result.suggestedMode)
        ? result.suggestedMode
        : 'neutral',
      confidence: typeof result.confidence === 'number'
        ? Math.min(1, Math.max(0, result.confidence))
        : 0.5,
      reason: result.reason || '',
    };
  } catch (err) {
    logger.warn({ err }, 'Post analyze failed — returning neutral');
    return { suggestedMode: 'neutral', confidence: 0, reason: '' };
  }
}

module.exports = { analyzePostContent };
