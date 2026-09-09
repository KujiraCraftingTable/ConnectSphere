/**
 * wikipediaService.js
 *
 * Tier 3 Wikipedia fallback for entity lookup.
 * Fetches entity data (EN summary + JA/VI langlinks + categories),
 * then uses LLM to parse into { canonical_name, category, aliases, genre_tags }.
 */

const { ollama } = require('../config/env');
const logger = require('../utils/logger');

// Generic category words — no Wikipedia lookup needed for these
const GENERIC_TAGS = new Set([
  'anime', 'manga', 'manhwa', 'manhua', 'movies', 'film', 'music', 'gaming', 'game',
  'travel', 'food', 'coffee', 'cafe', 'fitness', 'gym', 'coding', 'programming',
  'cooking', 'nature', 'lifestyle', 'sports', 'fashion', 'tech', 'science', 'art',
  'photography', 'reading', 'books', 'shopping', 'beauty', 'health',
  'fantasy', 'action', 'romance', 'comedy', 'horror', 'thriller', 'drama', 'sci-fi',
  'fantasy anime', 'action anime', 'shounen', 'shonen', 'seinen', 'josei', 'isekai',
  'pop music', 'rock music', 'hip hop', 'jazz', 'classical music', 'k-pop',
  'food and drink', 'milk tea', 'bubble tea',
  'software development', 'agile', 'sprint', 'teamwork',
  'vietnam', 'hanoi', 'ho chi minh city', 'da lat',
]);

const WIKI_HEADERS = { 'User-Agent': 'ConnectSphere/1.0 (education project)' };

const WIKI_PARSE_PROMPT = `Given Wikipedia data about an entity, extract structured information.
Return ONLY a JSON object. No explanation outside the JSON.

{
  "canonical_name": "official English Wikipedia page title",
  "category": "one of: Anime, Manga, Game, Movie, TVShow, Music, Artist, Book, Sport, Brand, Person, Place, Other",
  "aliases": ["all name variants — EN title, JA title, VI title, abbreviations, alternate spellings"],
  "genre_tags": ["lowercase genre/type search tags, e.g. anime, fantasy, action — NOT the entity name itself"]
}

Rules:
- canonical_name: use the exact Wikipedia EN page title
- aliases: include every language title provided + common short forms / abbreviations
- genre_tags: generic searchable terms only, all lowercase, no entity name, no CJK characters
- No duplicate values in any array`;

/** Returns true if tag is likely a proper noun that warrants a Wikipedia lookup. */
function isProperNoun(tag) {
  if (GENERIC_TAGS.has(tag.toLowerCase())) return false;
  // LLM capitalizes entity names; generic words stay lowercase
  return /[A-Z]/.test(tag);
}

/** Fetch Wikipedia REST summary + MediaWiki langlinks + categories for a term. */
async function searchWikipedia(term) {
  try {
    // ── Step 1: EN summary via REST API ─────────────────────────────────────
    const encoded    = encodeURIComponent(term.replace(/ /g, '_'));
    const summaryRes = await fetch(
      `https://en.wikipedia.org/api/rest_v1/page/summary/${encoded}`,
      { headers: WIKI_HEADERS, signal: AbortSignal.timeout(8_000) }
    );
    if (!summaryRes.ok) return null;

    const summary = await summaryRes.json();
    if (summary.type === 'disambiguation') return null;

    // ── Step 2: langlinks (JA, VI) + categories via MediaWiki API ───────────
    const params = new URLSearchParams({
      action:  'query',
      titles:  summary.title,
      prop:    'langlinks|categories',
      lllang:  'ja|vi',
      cllimit: '20',
      clshow:  '!hidden',
      format:  'json',
      origin:  '*',
    });

    const wikiRes = await fetch(
      `https://en.wikipedia.org/w/api.php?${params}`,
      { headers: WIKI_HEADERS, signal: AbortSignal.timeout(8_000) }
    );

    const titles     = { en: summary.title };
    let   categories = [];

    if (wikiRes.ok) {
      const wikiData = await wikiRes.json();
      const pages    = Object.values(wikiData.query?.pages || {});
      if (pages[0]) {
        for (const ll of (pages[0].langlinks || [])) {
          if (ll.lang === 'ja') titles.ja = ll['*'];
          if (ll.lang === 'vi') titles.vi = ll['*'];
        }
        categories = (pages[0].categories || [])
          .map(c => c.title.replace(/^Category:/, '').trim())
          .filter(c => !/^(Articles|CS1|Webarchive|Wikipedia|Pages|All articles|Coordinates)/i.test(c))
          .slice(0, 10);
      }
    }

    return {
      title:       summary.title,
      description: summary.description || '',
      extract:     (summary.extract || '').slice(0, 500),
      titles,
      categories,
    };
  } catch (err) {
    logger.warn({ err, term }, 'Wikipedia search failed');
    return null;
  }
}

/** Use LLM to parse Wikipedia data into a structured entity record. */
async function parseWikiData(wikiData) {
  try {
    const input = JSON.stringify({
      en_title:            wikiData.title,
      description:         wikiData.description,
      extract:             wikiData.extract,
      multilingual_titles: wikiData.titles,
      categories:          wikiData.categories,
    });

    const body = {
      model:    ollama.model,
      messages: [
        { role: 'system', content: WIKI_PARSE_PROMPT },
        { role: 'user',   content: input },
      ],
      options: { temperature: 0 },
      stream:  false,
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
    const start   = cleaned.indexOf('{');
    const end     = cleaned.lastIndexOf('}');
    if (start === -1 || end === -1) throw new Error('No JSON object in LLM response');

    const parsed = JSON.parse(cleaned.slice(start, end + 1));

    if (!parsed.canonical_name || !parsed.category) throw new Error('Missing required fields');
    if (!Array.isArray(parsed.aliases))    parsed.aliases    = [];
    if (!Array.isArray(parsed.genre_tags)) parsed.genre_tags = [];

    return parsed;
  } catch (err) {
    logger.warn({ err }, 'parseWikiData LLM failed');
    return null;
  }
}

module.exports = { isProperNoun, searchWikipedia, parseWikiData };
