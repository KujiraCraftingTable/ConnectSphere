const { ollama } = require('../config/env');
const logger = require('../utils/logger');

const ENTERTAINMENT_TYPES = new Set([
  'anime','manga','movie','tv_show','book','game','music','podcast','celebrity','art','food','sport',
]);

const WORK_TYPES = new Set([
  'company','university','industry','programming_language','framework','tool','certification','job_role','professional_field','startup',
]);

// ── Agent Prompts ─────────────────────────────────────────────────────────────

const AGENT0_PROMPT = `Translate the following text to English.
Rules:
- Preserve all proper nouns exactly as written: movie/anime/song titles, artist names, brand names, company names, university names, framework and tool names, place names
- Output ONLY the translated English text — no explanation, no quotes, no extra text
- If the input is already in English, output it unchanged

Examples:
"tìm bạn nữ xem Kimetsu no Yaiba" → "find female friend who watches Kimetsu no Yaiba"
"muốn kết bạn sinh viên RMIT học React" → "want to befriend RMIT student studying React"
"Ê Kujira ơi, mình thích cà phê và du lịch Đà Lạt" → "Hey Kujira, I like coffee and traveling to Da Lat"
"find iOS developer in Ho Chi Minh" → "find iOS developer in Ho Chi Minh"`;

const AGENT1_PROMPT = `You are a search intent classifier for a social network.
Given a search query, return JSON with exactly these 3 fields:
{
  "cleaned_query": "...",
  "mode": "friend" | "colleague" | null,
  "has_entity": true | false
}

cleaned_query: remove greetings ("Hey Kujira", "Hello", "hi"), filler phrases ("help me", "I want to", "can you"), and emotional noise ("I'm so sad", "it's raining today"). Keep only the core search intent.
mode: "friend" if looking for friends or social connections. "colleague" if looking for work or study partners. null if unclear.
has_entity: true if the query mentions a specific named entity — a movie, anime, song, artist, company, university, specific framework, tool, or certification name.

Return only valid JSON, no explanation.

Examples:
"Hey Kujira, I want to connect with a female who watches Kimetsu no Yaiba" → {"cleaned_query": "find female friend who watches Kimetsu no Yaiba", "mode": "friend", "has_entity": true}
"help me find an RMIT student studying React" → {"cleaned_query": "find RMIT student studying React", "mode": "colleague", "has_entity": true}
"I'm so lonely today, looking for someone to travel with" → {"cleaned_query": "find someone to travel with", "mode": "friend", "has_entity": false}
"find iOS developer in Ho Chi Minh" → {"cleaned_query": "find iOS developer in Ho Chi Minh", "mode": "colleague", "has_entity": false}`;

const AGENT2A_PROMPT = `You are an entity classifier for a social network search.
Given a search query, identify the specific named entity and return JSON:
{
  "entity_type": "anime"|"manga"|"movie"|"tv_show"|"book"|"game"|"music"|"podcast"|"celebrity"|"art"|"food"|"sport"|"company"|"university"|"industry"|"programming_language"|"framework"|"tool"|"certification"|"job_role"|"professional_field"|"startup",
  "entity_name": "canonical English name",
  "entity_keywords": ["keyword1", "keyword2", ...]
}

entity_keywords: include original name + common aliases + abbreviations, all lowercase.
If no specific entity found, return {"entity_type": null, "entity_name": null, "entity_keywords": []}.
Return only valid JSON, no explanation.

Examples:
"find female friend who watches Kimetsu no Yaiba" → {"entity_type": "anime", "entity_name": "Kimetsu no Yaiba", "entity_keywords": ["kimetsu no yaiba", "demon slayer", "kny"]}
"find RMIT student studying React" → {"entity_type": "framework", "entity_name": "React", "entity_keywords": ["react", "reactjs", "react.js"]}
"want to discuss Taylor Swift music" → {"entity_type": "music", "entity_name": "Taylor Swift", "entity_keywords": ["taylor swift", "taylorswift", "swiftie"]}
"find someone who likes One Piece" → {"entity_type": "anime", "entity_name": "One Piece", "entity_keywords": ["one piece", "onepiece", "op"]}
"find Google engineer" → {"entity_type": "company", "entity_name": "Google", "entity_keywords": ["google", "alphabet"]}
"find someone to travel with" → {"entity_type": null, "entity_name": null, "entity_keywords": []}`;

const LOCATION_LIST = '"Ho Chi Minh"|"Hanoi"|"Da Nang"|"Hai Phong"|"Can Tho"|"Hue"|"Tuyen Quang"|"Lao Cai"|"Thai Nguyen"|"Phu Tho"|"Bac Ninh"|"Hung Yen"|"Ninh Binh"|"Quang Tri"|"Quang Ngai"|"Gia Lai"|"Khanh Hoa"|"Lam Dong"|"Dak Lak"|"Dong Nai"|"Tay Ninh"|"Vinh Long"|"Dong Thap"|"Ca Mau"|"An Giang"|"Lai Chau"|"Dien Bien"|"Son La"|"Lang Son"|"Quang Ninh"|"Thanh Hoa"|"Nghe An"|"Ha Tinh"|"Cao Bang"';

const AGENT2B_FRIEND_PROMPT = `You are a semantic extractor for a social friend-search query.
Extract criteria and return JSON:
{
  "interest_groups": [],
  "bio_keywords": [],
  "location": null,
  "place_name": null
}

interest_groups: 2D array. Each inner array = one interest concept + synonyms (base-form nouns/verbs only, no adjectives, no emotion words).
  AND between groups (user must match ALL). OR within each group (any keyword matches).
  CORRECT: [["cook","cooking","food"],["travel","hiking","adventure"]]
  WRONG:   [["cook","travel"]] — never mix different concepts into one group

bio_keywords: words describing the person type (e.g. "student", "freelancer", "teacher")
location: exact match from this list only — ${LOCATION_LIST} — null if not mentioned
place_name: specific venue name when city is unknown (e.g. "CGV Go Vap", "Highlands Le Loi") — null if not mentioned

Think step by step: identify each concept in the query, classify it (interest group / bio keyword / location / place name), group synonyms together. Write your reasoning first, then output the JSON.

Example 1:
Input: "find someone who paints and teaches kids on weekends near CGV Go Vap"
Reasoning:
- "paints" → creative hobby → interest group: ["paint","draw","art","sketch"]
- "teaches kids" → recurring activity → interest group: ["teaching","tutor","kids"]
- "on weekends" → time context → ignore
- "near CGV Go Vap" → specific venue, city unknown → place_name
Output: {"interest_groups": [["paint","draw","art","sketch"],["teaching","tutor","kids"]], "bio_keywords": [], "location": null, "place_name": "CGV Go Vap"}

Example 2:
Input: "find student friend in Hanoi who likes anime and coffee"
Reasoning:
- "student" → describes the person type → bio_keywords
- "Hanoi" → Vietnamese city in location list → location
- "anime" → distinct hobby, separate concept → interest group: ["anime","manga"]
- "coffee" → distinct lifestyle, separate concept → interest group: ["coffee","cafe"]
Output: {"interest_groups": [["anime","manga"],["coffee","cafe"]], "bio_keywords": ["student"], "location": "Hanoi", "place_name": null}`;

const AGENT2B_COLLEAGUE_PROMPT = `You are a semantic extractor for a professional colleague-search query.
Extract criteria and return JSON:
{
  "skills": [],
  "bio_keywords": [],
  "job_title_keywords": [],
  "location": null,
  "place_name": null
}

skills: work or study skills only (e.g. "iOS", "React", "Python", "Accounting", "Marketing", "Teaching")
bio_keywords: words describing the person type (e.g. "student", "freelancer", "senior")
job_title_keywords: job or role titles (e.g. "developer", "designer", "accountant")
location: exact match from this list only — ${LOCATION_LIST} — null if not mentioned
place_name: specific venue name when city is unknown — null if not mentioned

Think step by step: identify each concept in the query, classify it (skill / bio keyword / job title / location), then extract. Write your reasoning first, then output the JSON.

Example 1:
Input: "find senior iOS developer who also knows React and has fintech experience in Ho Chi Minh"
Reasoning:
- "senior" → experience level, describes the person → bio_keywords
- "iOS developer" → platform + role → skills: ["iOS","Swift"], job_title_keywords: ["developer"]
- "React" → framework → skills: ["React","JavaScript"]
- "fintech" → industry domain → skills: ["Fintech"]
- "Ho Chi Minh" → Vietnamese city in location list → location
Output: {"skills": ["iOS","Swift","React","JavaScript","Fintech"], "bio_keywords": ["senior"], "job_title_keywords": ["developer"], "location": "Ho Chi Minh", "place_name": null}

Example 2:
Input: "find accounting student who knows Excel and teaches part-time"
Reasoning:
- "accounting student" → field of study + person type → skills: ["Accounting"], bio_keywords: ["student"]
- "Excel" → tool skill → skills: ["Excel"]
- "teaches part-time" → secondary role → job_title_keywords: ["teacher"], bio_keywords: ["part-time"]
Output: {"skills": ["Accounting","Excel","Teaching"], "bio_keywords": ["student","part-time"], "job_title_keywords": ["teacher","accountant"], "location": null, "place_name": null}`;

const AGENT2B_GENERAL_PROMPT = `You are a semantic extractor for a social search query.
Extract criteria and return JSON:
{
  "interest_groups": [],
  "skills": [],
  "bio_keywords": [],
  "job_title_keywords": [],
  "location": null,
  "place_name": null
}

interest_groups: 2D array for hobbies/lifestyle (base-form nouns/verbs only, no adjectives).
  CORRECT: [["cook","cooking","food"],["travel","hiking","adventure"]]
  WRONG:   [["cook","travel"]] — never mix different concepts
skills: work/study skills only (iOS, React, Accounting...). Never put in interest_groups.
bio_keywords: words describing the person type
job_title_keywords: job or role titles
location: exact match from this list only — ${LOCATION_LIST} — null if not mentioned
place_name: specific venue name when city is unknown — null if not mentioned

Return only valid JSON, no explanation.

Examples:
"find someone who likes cooking and knows React" → {"interest_groups": [["cook","cooking","food"]], "skills": ["React"], "bio_keywords": [], "job_title_keywords": [], "location": null, "place_name": null}
"find iOS developer in Hanoi who loves anime" → {"interest_groups": [["anime","manga"]], "skills": ["iOS", "Swift"], "bio_keywords": [], "job_title_keywords": ["developer"], "location": "Hanoi", "place_name": null}`;

// ── Low-level helpers ─────────────────────────────────────────────────────────

async function callOllama(userQuery, systemPrompt, temperature = 0.1) {
  const body = {
    model: ollama.model,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user',   content: userQuery },
    ],
    options: { temperature },
    stream: false,
  };

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
 *  Anchors to after "Output:" when present so CoT reasoning text
 *  containing stray { } characters does not confuse the parser. */
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

// ── Agent 0: Translator ───────────────────────────────────────────────────────

/** Translate raw user input to English. Falls back to original on failure. */
async function translateToEnglish(query) {
  try {
    const result = await callOllama(query, AGENT0_PROMPT, 0);
    return result.trim() || query;
  } catch (err) {
    logger.warn({ err }, 'Agent0 (translate) failed — using original query');
    return query;
  }
}

// ── Agent 1: Mode Classifier + Noise Reducer ──────────────────────────────────

/** Detect mode, strip noise, and flag entity presence. Falls back to safe defaults on failure. */
async function classifyAndClean(englishQuery) {
  try {
    const raw  = await callOllama(englishQuery, AGENT1_PROMPT);
    const json = parseRawJSON(raw);
    return {
      cleaned_query: typeof json.cleaned_query === 'string' && json.cleaned_query.trim()
        ? json.cleaned_query.trim()
        : englishQuery,
      mode:       ['friend', 'colleague'].includes(json.mode) ? json.mode : null,
      has_entity: !!json.has_entity,
    };
  } catch (err) {
    logger.warn({ err }, 'Agent1 (classify) failed — using defaults');
    return { cleaned_query: englishQuery, mode: null, has_entity: true };
  }
}

// ── Agent 2a: Entity Classifier ───────────────────────────────────────────────

/** Classify the named entity in the query. Returns null on failure. */
async function classifyEntity(cleanedQuery) {
  try {
    const raw  = await callOllama(cleanedQuery, AGENT2A_PROMPT);
    const json = parseRawJSON(raw);
    return {
      entity_type:     json.entity_type     || null,
      entity_name:     json.entity_name     || null,
      entity_keywords: cleanKeywords(json.entity_keywords),
    };
  } catch (err) {
    logger.warn({ err }, 'Agent2a (entity) failed');
    return null;
  }
}

// ── Agent 2b: Semantic Extractor ──────────────────────────────────────────────

/** Extract interests, skills, location, and bio signals. Returns {} on failure. */
async function extractSemantics(cleanedQuery, mode) {
  const prompt =
    mode === 'friend'    ? AGENT2B_FRIEND_PROMPT :
    mode === 'colleague' ? AGENT2B_COLLEAGUE_PROMPT :
                           AGENT2B_GENERAL_PROMPT;
  try {
    const raw = await callOllama(cleanedQuery, prompt);
    return parseRawJSON(raw);
  } catch (err) {
    logger.warn({ err }, 'Agent2b (semantics) failed');
    return {};
  }
}

// ── Merge + Sanitize ──────────────────────────────────────────────────────────

/** Merge outputs from all agents, apply mode safety net, and generate tips. */
function sanitizeAndMerge(agent1, agent2a, agent2b, mode) {
  const rawGroups = Array.isArray(agent2b.interest_groups) ? agent2b.interest_groups : [];
  const interest_groups = rawGroups
    .filter(g => Array.isArray(g) && g.length > 0)
    .map(g => cleanKeywords(g))
    .filter(g => g.length > 0);
  const interests = [...new Set(interest_groups.flat())];

  const result = {
    entity_type:        agent2a?.entity_type        || null,
    entity_name:        agent2a?.entity_name        || null,
    entity_keywords:    agent2a?.entity_keywords    || [],
    interest_groups,
    interests,
    skills:             cleanKeywords(agent2b.skills),
    bio_keywords:       cleanKeywords(agent2b.bio_keywords),
    job_title_keywords: cleanKeywords(agent2b.job_title_keywords),
    location:           agent2b.location   || null,
    place_name:         agent2b.place_name || null,
    mode,
    reasoning:          '',
    tips:               '',
  };

  // Safety net: strip fields that don't belong to the active mode
  if (mode === 'friend') {
    result.skills             = [];
    result.job_title_keywords = [];
    if (result.entity_type && WORK_TYPES.has(result.entity_type)) {
      result.entity_type     = null;
      result.entity_name     = null;
      result.entity_keywords = [];
    }
  }

  if (mode === 'colleague') {
    result.interest_groups = [];
    result.interests       = [];
    if (result.entity_type && ENTERTAINMENT_TYPES.has(result.entity_type)) {
      result.entity_type     = null;
      result.entity_name     = null;
      result.entity_keywords = [];
    }
  }

  result.tips = generateFallbackTips(result, mode);
  return result;
}

// ── Main entry point ──────────────────────────────────────────────────────────

async function extractSearchCriteria(userQuery, mode = null) {
  // Agent 0: normalize input to English
  const englishQuery = await translateToEnglish(userQuery.trim());
  logger.debug({ englishQuery }, 'Agent0: translated');

  // Agent 1: classify mode and strip noise
  const agent1 = await classifyAndClean(englishQuery);
  logger.debug({ agent1 }, 'Agent1: classified');

  const cleanedQuery = agent1.cleaned_query;
  const resolvedMode = mode ?? agent1.mode;

  // Agent 2a (entity) and 2b (semantics) in parallel
  // 2a only runs when Agent 1 detected a named entity
  const [agent2a, agent2b] = await Promise.all([
    agent1.has_entity
      ? classifyEntity(cleanedQuery)
      : Promise.resolve(null),
    extractSemantics(cleanedQuery, resolvedMode),
  ]);
  logger.debug({ agent2a, agent2b }, 'Agent2: entity + semantics');

  return sanitizeAndMerge(agent1, agent2a, agent2b, resolvedMode);
}

// ── Embedding ─────────────────────────────────────────────────────────────────

/** Embed a text string using mxbai-embed-large. Returns number[] or null on failure. */
async function embedText(text) {
  try {
    const response = await fetch(`${ollama.url}/api/embeddings`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ model: 'mxbai-embed-large', prompt: text }),
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

// ── Tips generator (programmatic — no LLM) ───────────────────────────────────

function generateFallbackTips(result, mode) {
  const hasInterests = result.interests.length > 0;
  const hasSkills    = result.skills.length > 0;
  const hasEntity    = !!result.entity_name;
  const hasLocation  = !!result.location;
  const hasBio       = result.bio_keywords.length > 0;

  const filledCount = [hasInterests || hasSkills, hasEntity, hasLocation, hasBio].filter(Boolean).length;

  if (mode === 'friend') {
    if (filledCount === 0) return 'Ôi, Kujira chưa hiểu rõ bạn muốn tìm ai rồi! 🥺 Thêm sở thích cụ thể (anime, café, du lịch...) hoặc khu vực bạn ở để Kujira tìm chuẩn hơn nhé~ ✨';
    if (filledCount >= 3) return 'Wow, bạn mô tả rõ quá luôn! 🌟 Kujira đã tìm được những người phù hợp nhất rồi đây~ 🎊';
    const missing = [];
    if (!hasLocation) missing.push('địa điểm của bạn 📍');
    if (!hasEntity && !hasInterests) missing.push('sở thích cụ thể 🎯');
    if (!hasBio) missing.push('thêm mô tả về bản thân 💬');
    return `Đang đi đúng hướng rồi nè! 🎉 Thêm ${missing.slice(0, 2).join(' hoặc ')} để Kujira tìm được bạn phù hợp hơn cho bạn nhé! 💕`;
  }

  if (mode === 'colleague') {
    if (filledCount === 0) return 'Kujira chưa đủ thông tin để tìm chính xác đâu! 💼 Thêm kỹ năng, lĩnh vực hoặc địa điểm để Kujira giúp tốt hơn nhé!';
    if (filledCount >= 3) return 'Xịn quá! 🎯 Kujira đã tối ưu kết quả theo yêu cầu của bạn rồi đây~ ✅';
    const missing = [];
    if (!hasLocation) missing.push('địa điểm 📌');
    if (!hasSkills) missing.push('kỹ năng cụ thể 💡');
    if (!hasBio) missing.push('mô tả thêm 📝');
    return `Ổn rồi đó! Thêm ${missing.slice(0, 2).join(' hoặc ')} để Kujira tìm được người phù hợp hơn cho bạn nha. 🎯`;
  }

  if (filledCount === 0) return 'Kujira chưa rõ bạn muốn tìm ai~ 🐳 Thêm sở thích, kỹ năng hoặc địa điểm cụ thể để Kujira tìm chuẩn hơn nhé!';
  if (filledCount >= 3) return 'Thông tin rất đầy đủ! 🌟 Kujira đã tìm được những người phù hợp nhất cho bạn rồi~ 🎊';
  return 'Kujira đã tìm kiếm dựa trên thông tin bạn cung cấp rồi! Thêm địa điểm hoặc mô tả thêm để kết quả chính xác hơn nhé~ 💕';
}

module.exports = { extractSearchCriteria, embedText };
