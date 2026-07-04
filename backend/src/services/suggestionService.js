/**
 * suggestionService.js
 *
 * Generates 4 AI search suggestions per mode based on trending queries (last 7 days).
 * Results are cached in the suggestion_cache DB table with a 1-hour TTL.
 */

const { query } = require('../config/db');
const { ollama } = require('../config/env');
const logger = require('../utils/logger');

const CACHE_TTL_MS = 60 * 60 * 1000; // 1 hour

const DEFAULT_SUGGESTIONS = {
  friend: [
    'tìm bạn thích anime để hẹn hò cuối tuần',
    'tìm người có cùng sở thích xem phim',
    'tìm bạn chơi game online cùng',
    'tìm người thích du lịch khám phá',
  ],
  colleague: [
    'tìm iOS developer sinh viên có hứng thú chung',
    'tìm đồng nghiệp làm React ở Hồ Chí Minh',
    'tìm sinh viên kế toán muốn học nhóm',
    'tìm designer có kinh nghiệm Figma',
  ],
};

const LLM_PROMPT = {
  friend: `Bạn đang phân tích xu hướng tìm bạn bè trên ConnectSphere trong 7 ngày qua.

Các query tìm kiếm phổ biến nhất:
{QUERIES}

Tạo 4 câu gợi ý tìm kiếm tiếng Việt cho người muốn tìm BẠN BÈ để chơi, giải trí, hẹn hò.
Mỗi câu phải ngắn gọn, tự nhiên, phản ánh xu hướng trên.
Trả về JSON thuần túy: {"suggestions": ["...", "...", "...", "..."]}`,

  colleague: `Bạn đang phân tích xu hướng tìm đồng nghiệp/cộng tác viên trên ConnectSphere trong 7 ngày qua.

Các query tìm kiếm phổ biến nhất:
{QUERIES}

Tạo 4 câu gợi ý tìm kiếm tiếng Việt cho người muốn tìm ĐỒNG NGHIỆP, CỘT TÁC VIÊN hoặc SINH VIÊN để học tập/làm việc.
Mỗi câu phải ngắn gọn, tự nhiên, phản ánh xu hướng trên.
Trả về JSON thuần túy: {"suggestions": ["...", "...", "...", "..."]}`,
};

// ─── Cache helpers ────────────────────────────────────────────────────────────

async function readCache(mode) {
  const { rows } = await query(
    `SELECT suggestions, computed_at FROM suggestion_cache WHERE mode = $1`,
    [mode]
  );
  if (!rows[0]) return null;
  const ageMs = Date.now() - new Date(rows[0].computed_at).getTime();
  if (ageMs > CACHE_TTL_MS) return null;
  return rows[0].suggestions; // pg parses JSONB → already an array
}

async function writeCache(mode, suggestions) {
  await query(
    `INSERT INTO suggestion_cache (mode, suggestions, computed_at)
     VALUES ($1, $2::jsonb, NOW())
     ON CONFLICT (mode) DO UPDATE
       SET suggestions  = EXCLUDED.suggestions,
           computed_at  = NOW()`,
    [mode, JSON.stringify(suggestions)]
  );
}

// ─── Trending query fetch ─────────────────────────────────────────────────────

async function fetchTrendingQueries(mode) {
  const { rows } = await query(
    `SELECT query, COUNT(*) AS cnt
     FROM search_logs
     WHERE mode = $1
       AND created_at > NOW() - INTERVAL '7 days'
     GROUP BY query
     ORDER BY cnt DESC
     LIMIT 20`,
    [mode]
  );
  return rows.map(r => r.query);
}

// ─── LLM call ─────────────────────────────────────────────────────────────────

async function callLLM(prompt) {
  const messages = [{ role: 'user', content: prompt }];

  const res = await fetch(`${ollama.url}/api/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: ollama.model, messages, options: { temperature: 0.4 }, stream: false }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) throw new Error(`Ollama error: ${res.status}`);
  const raw = (await res.json()).message?.content ?? '';

  // Strip markdown fences
  const cleaned = raw
    .replace(/```json\s*/gi, '')
    .replace(/```\s*/g, '')
    .trim();

  const start = cleaned.indexOf('{');
  const end   = cleaned.lastIndexOf('}');
  if (start === -1 || end === -1) throw new Error('No JSON in LLM response');

  const json = JSON.parse(cleaned.slice(start, end + 1));
  if (!Array.isArray(json.suggestions) || json.suggestions.length === 0) {
    throw new Error('Invalid suggestions format');
  }
  return json.suggestions.slice(0, 4);
}

// ─── Main export ──────────────────────────────────────────────────────────────

/**
 * Returns 4 suggestions for the given mode.
 * Serves from DB cache if fresh, otherwise recomputes from trending queries + LLM.
 */
async function getSuggestions(mode) {
  if (mode !== 'friend' && mode !== 'colleague') {
    return [...DEFAULT_SUGGESTIONS.friend, ...DEFAULT_SUGGESTIONS.colleague].slice(0, 4);
  }

  // 1. Try cache
  const cached = await readCache(mode);
  if (cached) {
    logger.debug({ mode }, 'Serving suggestions from cache');
    return cached;
  }

  // 2. Fetch trending queries
  const queries = await fetchTrendingQueries(mode);
  logger.debug({ mode, count: queries.length }, 'Fetched trending queries');

  // 3. Not enough data → return defaults
  if (queries.length < 3) {
    logger.debug({ mode }, 'Not enough trending data — using defaults');
    await writeCache(mode, DEFAULT_SUGGESTIONS[mode]);
    return DEFAULT_SUGGESTIONS[mode];
  }

  // 4. LLM generate
  try {
    const queriesText = queries.map((q, i) => `${i + 1}. "${q}"`).join('\n');
    const prompt = LLM_PROMPT[mode].replace('{QUERIES}', queriesText);
    const suggestions = await callLLM(prompt);
    await writeCache(mode, suggestions);
    logger.info({ mode }, 'Suggestions recomputed and cached');
    return suggestions;
  } catch (err) {
    logger.warn({ err, mode }, 'LLM suggestion generation failed — using defaults');
    await writeCache(mode, DEFAULT_SUGGESTIONS[mode]);
    return DEFAULT_SUGGESTIONS[mode];
  }
}

module.exports = { getSuggestions };
