const { ollama } = require('../config/env');
const logger = require('../utils/logger');

const ENTERTAINMENT_TYPES = new Set([
  'anime','manga','movie','tv_show','book','game','music','podcast','celebrity','art','food','sport',
]);

const WORK_TYPES = new Set([
  'company','university','industry','programming_language','framework','tool','certification','job_role','professional_field','startup',
]);

// ── Query Understanding — one combined prompt ────────────────────────────────
// Deliberately ONE prompt, not three. Ollama caches the prompt prefix per slot,
// so rotating several system prompts through one slot made every call a cache
// miss — measured at 7.35s of pure prompt re-reading across the old 3-call
// pipeline, vs 0.05s once a single prompt stays resident.

const LOCATION_LIST = '"Ho Chi Minh"|"Hanoi"|"Da Nang"|"Hai Phong"|"Can Tho"|"Hue"|"Tuyen Quang"|"Lao Cai"|"Thai Nguyen"|"Phu Tho"|"Bac Ninh"|"Hung Yen"|"Ninh Binh"|"Quang Tri"|"Quang Ngai"|"Gia Lai"|"Khanh Hoa"|"Lam Dong"|"Dak Lak"|"Dong Nai"|"Tay Ninh"|"Vinh Long"|"Dong Thap"|"Ca Mau"|"An Giang"|"Lai Chau"|"Dien Bien"|"Son La"|"Lang Son"|"Quang Ninh"|"Thanh Hoa"|"Nghe An"|"Ha Tinh"|"Cao Bang"';

const ANALYZER_PROMPT = `You are a query analyzer for a social network people-search.
Analyze the search query (any language) and return JSON.

intent_en: the core search intent translated to English. Preserve proper nouns exactly (anime/movie/song titles, artist names, team names, brands, companies, universities, frameworks, tools, places). Remove greetings, filler ("help me", "I want to"), and emotional noise. Keep only what describes WHO the user wants to find.
mode: "hobby" if looking for friends or social connections, "work" if looking for work or study partners, null if unclear.
target_gender: "male" or "female" ONLY when explicitly asked ("bạn nam", "female friend"). Never guess from context.
target_age_min / target_age_max: ALWAYS set these when the query mentions any age — never skip them. "20-30" -> min 20, max 30. "over 25"/"trên 25"/"trên 25 tuổi" -> min 25, max null. "under 30"/"dưới 30" -> min null, max 30. A single age ("25 tuổi", "around 25") -> a ±2 range, min 23 max 27. Only omit when no age is mentioned at all.
entity_type: type of the specific named entity, one of: anime, manga, movie, tv_show, book, game, music, podcast, celebrity, art, food, sport, company, university, industry, programming_language, framework, tool, certification, job_role, professional_field, startup. null if the query names no specific entity.
entity_name: canonical English name of that entity. null if none.
interest_groups: 2D array for hobbies/lifestyle. Each inner array is ONE concept plus its synonyms, base-form nouns/verbs only, no adjectives or emotion words. AND between groups, OR within a group. CORRECT: [["cook","cooking","food"],["travel","hiking"]]. WRONG: [["cook","travel"]] — never mix concepts.
skills: work or study skills only (iOS, React, Python, Accounting, Marketing). Never put these in interest_groups.
bio_keywords: words describing the person type (student, freelancer, senior, teacher).
job_title_keywords: job or role titles (developer, designer, accountant).
location: exact match from this list only — ${LOCATION_LIST} — null if not mentioned.
place_name: a specific venue name when the city is unknown (e.g. "CGV Go Vap"). null if not mentioned.

For a hobby-mode query leave skills and job_title_keywords empty. For a work-mode query leave interest_groups empty.

Omit any field that is null or empty — do not emit null or [] values. Output compact JSON on one line, no explanation.

Example: "tìm bạn nữ xem Kimetsu no Yaiba ở Hà Nội"
{"intent_en":"find female friend who watches Kimetsu no Yaiba in Hanoi","mode":"hobby","target_gender":"female","entity_type":"anime","entity_name":"Kimetsu no Yaiba","interest_groups":[["anime","manga"]],"location":"Hanoi"}

Example: "find senior iOS developer who knows React in Ho Chi Minh"
{"intent_en":"find senior iOS developer who knows React in Ho Chi Minh","mode":"work","entity_type":"framework","entity_name":"React","skills":["iOS","Swift","React"],"bio_keywords":["senior"],"job_title_keywords":["developer"],"location":"Ho Chi Minh"}

Example: "tìm bạn nam trên 25 tuổi thích đá banh gần CGV Go Vap"
{"intent_en":"find male friend over 25 years old who likes football near CGV Go Vap","mode":"hobby","target_gender":"male","target_age_min":25,"interest_groups":[["football","soccer"]],"place_name":"CGV Go Vap"}`;


// ── JSON schema (Ollama `format`) ───────────────────────────────────────────
// Constrains decoding to schema-valid tokens instead of prompting for JSON and
// parsing free text. Only intent_en/mode are required — everything else is
// omittable, which keeps the generated output (and therefore latency) small.
// entity_keywords is deliberately absent: buildEntityVector already resolves
// aliases through the interest_entities table, so making the model spell them
// out cost tokens for no gain.

const ANALYZER_SCHEMA = {
  type: 'object',
  properties: {
    intent_en:          { type: 'string' },
    mode:               { type: ['string', 'null'], enum: ['hobby', 'work', null] },
    target_gender:      { type: ['string', 'null'], enum: ['male', 'female', null] },
    target_age_min:     { type: ['integer', 'null'] },
    target_age_max:     { type: ['integer', 'null'] },
    entity_type:        { type: ['string', 'null'], enum: [...ENTERTAINMENT_TYPES, ...WORK_TYPES, null] },
    entity_name:        { type: ['string', 'null'] },
    interest_groups:    { type: 'array', items: { type: 'array', items: { type: 'string' } } },
    skills:             { type: 'array', items: { type: 'string' } },
    bio_keywords:       { type: 'array', items: { type: 'string' } },
    job_title_keywords: { type: 'array', items: { type: 'string' } },
    location:           { type: ['string', 'null'] },
    place_name:         { type: ['string', 'null'] },
  },
  required: ['intent_en', 'mode'],
};


// ── Low-level helpers ─────────────────────────────────────────────────────────

// keep_alive keeps the model resident between requests — without it, Ollama's
// server default unloads an idle model after 5 minutes, and the next call pays
// a multi-second reload tax. Both models this app uses fit in memory at once.
const KEEP_ALIVE = '30m';

async function callOllama(userQuery, systemPrompt, temperature = 0.1, schema = null) {
  const body = {
    model: ollama.model,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user',   content: userQuery },
    ],
    options: { temperature },
    stream: false,
    keep_alive: KEEP_ALIVE,
  };
  if (schema) body.format = schema;

  const response = await fetch(`${ollama.url}/api/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });

  if (!response.ok) {
    throw new Error(`Ollama error: ${response.status} ${response.statusText}`);
  }

  const data = await response.json();
  return data.message?.content ?? '';
}

/** Strip markdown fences and parse the JSON object in LLM output.
 *  Kept as a defensive fallback: the schema `format` should already guarantee
 *  clean JSON, but this costs nothing and covers a malformed response. */
function parseRawJSON(raw) {
  const cleaned = raw
    .replace(/```json\s*/gi, '')
    .replace(/```\s*/g, '')
    .trim();
  const outputIdx = cleaned.indexOf('Output:');
  const start = cleaned.indexOf('{', outputIdx !== -1 ? outputIdx : 0);
  const end   = cleaned.lastIndexOf('}');
  if (start === -1 || end === -1) throw new Error('No JSON object found in LLM response');
  return JSON.parse(cleaned.slice(start, end + 1));
}

const CJK_RE = /[　-鿿가-힯぀-ゟ゠-ヿ一-鿿]/;
const SENTIMENT_PREFIX_RE = /^(thích|muốn|quan tâm đến|quan tâm|mê|đam mê|hứng thú với|hứng thú|yêu thích|yêu|like|love|enjoy|want to|interested in)\s+/i;
const INVALID_ADJECTIVES = new Set([
  'thirsty','hungry','romantic','beautiful','pretty','cute','lovely','handsome',
  'funny','happy','sad','lonely','bored','tired','excited','nervous','anxious',
  'smart','clever','kind','nice','cool','awesome','great','good','bad',
  'interesting','amazing','wonderful','fantastic','incredible','brilliant',
  'creative','talented','passionate','enthusiastic','motivated','inspired',
  'active','social','friendly','outgoing','introverted','adventurous','spontaneous',
  'calm','relaxed','busy','lazy','serious','playful','wild','gentle','strong',
  'hunger','thirst','appetite','craving','desire','longing','feeling','emotion',
  'mood','vibe','energy','spirit','soul','mind','heart','love','hate',
  'thick drink','thick','drink food','good food','tasty','delicious','yummy',
  'nice food','good drink','thing','stuff','things','something','everything',
]);

const cleanKeywords = (arr) =>
  Array.isArray(arr)
    ? arr
        .map(k => (typeof k === 'string' ? k.replace(SENTIMENT_PREFIX_RE, '').trim() : ''))
        .filter(k => k && !CJK_RE.test(k) && !INVALID_ADJECTIVES.has(k.toLowerCase()))
    : [];

// ── Query analysis — one LLM call ─────────────────────────────────────────────

/** Sanitize a raw target age (min/max) pair: must be integers in [0,120] with
 *  min <= max, otherwise null out the offending value(s) rather than throwing —
 *  matches the file's fail-safe-to-null pattern. */
function sanitizeAgeRange(rawMin, rawMax) {
  const clean = (v) => {
    const n = Number.isInteger(v) ? v : (typeof v === 'string' ? parseInt(v, 10) : NaN);
    return Number.isInteger(n) && n >= 0 && n <= 120 ? n : null;
  };
  let min = clean(rawMin);
  let max = clean(rawMax);
  if (min != null && max != null && min > max) { min = null; max = null; }
  return { target_age_min: min, target_age_max: max };
}

/** Translate, denoise, and extract every search criterion in a single call.
 *  Falls back to safe defaults on failure, same as the stages it replaces. */
async function analyzeQuery(query) {
  try {
    const raw  = await callOllama(query, ANALYZER_PROMPT, 0.1, ANALYZER_SCHEMA);
    const json = parseRawJSON(raw);
    const { target_age_min, target_age_max } = sanitizeAgeRange(json.target_age_min, json.target_age_max);
    return {
      intent_en: typeof json.intent_en === 'string' && json.intent_en.trim()
        ? json.intent_en.trim()
        : query,
      mode:          ['hobby', 'work'].includes(json.mode) ? json.mode : null,
      target_gender: ['male', 'female'].includes(json.target_gender) ? json.target_gender : null,
      target_age_min,
      target_age_max,
      entity_type:   json.entity_type || null,
      entity_name:   json.entity_name || null,
      semantics: {
        interest_groups:    json.interest_groups,
        skills:             json.skills,
        bio_keywords:       json.bio_keywords,
        job_title_keywords: json.job_title_keywords,
        location:           json.location,
        place_name:         json.place_name,
      },
    };
  } catch (err) {
    logger.warn({ err }, 'Query analyzer failed — using defaults');
    return {
      intent_en: query, mode: null, target_gender: null,
      target_age_min: null, target_age_max: null,
      entity_type: null, entity_name: null, semantics: {},
    };
  }
}

// ── Merge + Sanitize ──────────────────────────────────────────────────────────

// Province names the `location` hard filter can actually match, parsed from the
// same LOCATION_LIST the prompt shows the model.
const VALID_LOCATIONS = new Set(
  LOCATION_LIST.split('|').map(s => s.replace(/"/g, '').trim().toLowerCase())
);

/** Keep `location` only when it names a province the filter can match; anything
 *  else (usually a venue) becomes `place_name` for the geocoder to resolve. */
function reconcileLocation(location, placeName) {
  const loc = typeof location === 'string' ? location.trim() : '';
  const place = typeof placeName === 'string' ? placeName.trim() : '';
  if (loc && !VALID_LOCATIONS.has(loc.toLowerCase())) {
    return { location: null, place_name: place || loc };
  }
  return { location: loc || null, place_name: place || null };
}

/** Merge the analyzer's output into the criteria shape, applying the mode safety net. */
function sanitizeAndMerge(normalized, entityInfo, semantics, mode) {
  const rawGroups = Array.isArray(semantics.interest_groups) ? semantics.interest_groups : [];
  const interest_groups = rawGroups
    .filter(g => Array.isArray(g) && g.length > 0)
    .map(g => cleanKeywords(g))
    .filter(g => g.length > 0);
  const interests = [...new Set(interest_groups.flat())];

  const result = {
    intent_en:          normalized.intent_en            || '',
    target_gender:      normalized.target_gender        || null,
    target_age_min:     normalized.target_age_min       ?? null,
    target_age_max:     normalized.target_age_max       ?? null,
    entity_type:        entityInfo?.entity_type        || null,
    entity_name:        entityInfo?.entity_name        || null,
    entity_keywords:    entityInfo?.entity_keywords    || [],
    interest_groups,
    interests,
    skills:             cleanKeywords(semantics.skills),
    bio_keywords:       cleanKeywords(semantics.bio_keywords),
    job_title_keywords: cleanKeywords(semantics.job_title_keywords),
    // The model is told to only use names from LOCATION_LIST, but it sometimes
    // puts a venue there anyway ("CGV Go Vap"). location feeds a `u.location
    // ILIKE` hard filter, so an off-list value silently matches nobody —
    // reclassify it as place_name, which is exactly the field for "a venue whose
    // city we don't know yet" and which the geocoder then resolves.
    ...reconcileLocation(semantics.location, semantics.place_name),
    mode,
  };

  // Safety net: strip fields that don't belong to the active mode
  if (mode === 'hobby') {
    result.skills             = [];
    result.job_title_keywords = [];
    if (result.entity_type && WORK_TYPES.has(result.entity_type)) {
      result.entity_type     = null;
      result.entity_name     = null;
      result.entity_keywords = [];
    }
  }

  if (mode === 'work') {
    result.interest_groups = [];
    result.interests       = [];
    if (result.entity_type && ENTERTAINMENT_TYPES.has(result.entity_type)) {
      result.entity_type     = null;
      result.entity_name     = null;
      result.entity_keywords = [];
    }
  }

  return result;
}

// ── Main entry point ──────────────────────────────────────────────────────────

async function extractSearchCriteria(userQuery, mode = null) {
  const start = Date.now();
  const analyzed = await analyzeQuery(userQuery.trim());
  logger.info({ durationMs: Date.now() - start, analyzed }, 'AI search: query analysis done');

  const resolvedMode = mode ?? analyzed.mode;
  const entityInfo = analyzed.entity_name || analyzed.entity_type
    ? { entity_type: analyzed.entity_type, entity_name: analyzed.entity_name, entity_keywords: [] }
    : null;

  return sanitizeAndMerge(analyzed, entityInfo, analyzed.semantics, resolvedMode);
}

// ── Translation (reused by chunkService to normalize chunk text) ──────────────

const TRANSLATE_PROMPT = `Translate the following text to English.
Rules:
- Preserve all proper nouns exactly as written: movie/anime/song titles, artist names, team names, brand/company names, university names, framework and tool names, place names
- Output ONLY the translated English text — no explanation, no quotes, no extra text
- If the input is already in English, output it unchanged`;

/** Translate free text to English for embedding. Falls back to the original on failure. */
async function translateToEnglish(text) {
  if (!text?.trim()) return text;
  try {
    const result = await callOllama(text, TRANSLATE_PROMPT, 0);
    return result.trim() || text;
  } catch (err) {
    logger.warn({ err }, 'translateToEnglish failed — using original text');
    return text;
  }
}

// ── Embedding ─────────────────────────────────────────────────────────────────

/** Embed a text string using mxbai-embed-large. Returns number[] or null on failure. */
async function embedText(text) {
  try {
    const response = await fetch(`${ollama.url}/api/embeddings`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ model: 'mxbai-embed-large', prompt: text, keep_alive: KEEP_ALIVE }),
      signal:  AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new Error(`Embed error: ${response.status}`);
    const data = await response.json();
    return data.embedding ?? null;
  } catch (err) {
    logger.warn({ err }, 'embedText failed');
    return null;
  }
}
module.exports = { extractSearchCriteria, embedText, translateToEnglish };
