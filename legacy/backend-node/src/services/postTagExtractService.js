/**
 * postTagExtractService.js
 *
 * Pipeline:
 *   1. LLM extract  — get raw entity/topic terms from post text
 *   2. Entity expand — 3-tier lookup (exact → vector → Wikipedia) per tag
 *                      Wikipedia tier saves new entities to interest_entities automatically
 *   3. Save          — bulk-insert deduped tags into post_tags
 */

const { ollama } = require('../config/env');
const { lookupEntity } = require('./entityLookupService');
const { query } = require('../config/db');
const logger = require('../utils/logger');

const SYSTEM_PROMPT = `You extract topics and entities from a social media post to use as searchable tags.
Return ONLY a JSON array of strings. No explanation outside the array.
All values must be in English.

── WHAT TO EXTRACT ──────────────────────────────────────────────────
Extract TWO layers:
1. Specific entities   — exact titles, character names, artist/band names, brand names, franchise names, company names, game titles, series names
2. Category tags       — genre (anime, fantasy, action), activity (coffee, travel, coding), domain (fitness, music, cooking)

── WHAT NOT TO EXTRACT ──────────────────────────────────────────────
NEVER extract:
- Emotions, moods or feelings: "happy", "sad", "excited", "positive mood", "good vibes", "chill", "relax"
- Adjectives describing quality: "amazing", "great", "awesome", "beautiful", "interesting", "funny"
- Relationship/social words: "friend", "bạn", "người yêu", "couple", "together"
- Filler/reaction words: "wow", "omg", "vãi", "lol", "haha"
- Vague lifestyle words unless specific: "life", "daily", "routine", "moment", "thing"
- Non-Latin characters (Japanese, Chinese, Korean): ウィストリア, 呪術廻戦

── VIETNAMESE → ENGLISH MAPPING (always translate) ──────────────────
"xem anime/manga"    → ["anime", "manga"]
"xem phim"          → ["movies", "film"]
"nghe nhạc"         → ["music"]
"đi cafe / cà phê"  → ["coffee", "cafe"]
"chơi game"         → ["gaming"]
"nấu ăn / ẩm thực"  → ["cooking", "food"]
"đi du lịch"        → ["travel"]
"gym / chạy bộ"     → ["fitness", "gym"]
"lập trình / code"  → ["programming", "coding"]
"sprint / deadline" → ["software development", "agile"]

── EXAMPLES ─────────────────────────────────────────────────────────
"Ôi mình thích bộ wistoria vãi, Gallus đánh hay lắm!"
→ ["Wistoria", "Wistoria: Wand and Sword", "Gallus", "anime", "fantasy anime", "magic anime", "action anime"]

"Tập mới của Jujutsu Kaisen ra rồi nè"
→ ["Jujutsu Kaisen", "JJK", "anime", "action anime", "shounen"]

"Hôm nay đi cafe với bạn, uống trà sữa ngon ghê"
→ ["coffee", "cafe", "milk tea", "food and drink"]

"Vừa xong sprint, team làm việc hiệu quả lắm"
→ ["software development", "agile", "sprint", "teamwork", "programming"]

"Đi Đà Lạt với gia đình, cảnh đẹp quá"
→ ["travel", "Da Lat", "Vietnam", "nature"]

"Nghe Taylor Swift cả ngày không chán"
→ ["Taylor Swift", "music", "pop music"]`;

/** Call LLM to extract raw topic terms from post content. */
async function extractRawTags(content) {
  try {
    const body = {
      model: ollama.model,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user',   content },
      ],
      options: { temperature: 0.2 },
      stream: false,
    };

    const response = await fetch(`${ollama.url}/api/chat`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
      signal:  AbortSignal.timeout(30_000),
    });

    if (!response.ok) throw new Error(`LLM error: ${response.status}`);

    const data    = await response.json();
    const raw     = data.message?.content ?? '';
    const cleaned = raw.replace(/```json\s*/gi, '').replace(/```\s*/g, '').trim();
    const start   = cleaned.indexOf('[');
    const end     = cleaned.lastIndexOf(']');
    if (start === -1 || end === -1) throw new Error('No JSON array in LLM response');

    const parsed = JSON.parse(cleaned.slice(start, end + 1));
    if (!Array.isArray(parsed)) throw new Error('LLM response is not an array');

    return parsed.filter(t => typeof t === 'string' && t.trim());
  } catch (err) {
    logger.warn({ err }, 'postTagExtract: LLM extraction failed');
    return [];
  }
}

/**
 * Expand each raw tag via all 3 tiers (exact → vector → Wikipedia).
 * Adds canonical name + aliases from interest_entities.
 * For Wikipedia hits, also adds genre_tags (e.g. "anime", "fantasy") returned by LLM parse.
 */
async function expandTags(rawTags) {
  const allTags = new Set(rawTags.map(t => t.toLowerCase().trim()));

  await Promise.allSettled(
    rawTags.map(async (tag) => {
      try {
        const result = await lookupEntity(tag);
        if (result.confidence === 'none' || !result.entity_id) return;

        const { rows } = await query(
          `SELECT canonical_name, aliases FROM interest_entities WHERE id = $1`,
          [result.entity_id]
        );
        if (!rows[0]) return;

        allTags.add(rows[0].canonical_name.toLowerCase().trim());
        for (const alias of (rows[0].aliases || [])) {
          allTags.add(alias.toLowerCase().trim());
        }

        // Wikipedia tier also returns genre/type tags (e.g. "anime", "fantasy anime")
        if (result.genre_tags?.length) {
          for (const gt of result.genre_tags) {
            allTags.add(gt.toLowerCase().trim());
          }
        }
      } catch (err) {
        logger.warn({ err, tag }, 'postTagExtract: entity expand failed for tag');
      }
    })
  );

  return [...allTags].filter(Boolean);
}

/** Bulk-insert AI-extracted tags into post_tags, ignoring duplicates. */
async function savePostTags(postId, tags) {
  if (!tags.length) return;
  await query(
    `INSERT INTO post_tags (post_id, tag, source)
     SELECT $1, UNNEST($2::text[]), 'ai'
     ON CONFLICT (post_id, tag) DO NOTHING`,
    [postId, tags]
  );
}

/** Full pipeline: LLM extract → tier-1 entity expand → deduplicate → save. */
async function extractAndSaveTags(postId, content) {
  if (!content?.trim()) return;

  const rawTags = await extractRawTags(content);
  if (!rawTags.length) {
    logger.debug({ postId }, 'postTagExtract: no tags extracted');
    return;
  }

  const tags = await expandTags(rawTags);
  await savePostTags(postId, tags);
  logger.info({ postId, count: tags.length, tags }, 'postTagExtract: tags saved');
}

module.exports = { extractAndSaveTags };
