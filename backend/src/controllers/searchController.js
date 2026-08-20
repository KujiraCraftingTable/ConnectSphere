const { extractSearchCriteria, embedText } = require('../services/aiService');
const {
  vectorSearch,
  findCommunityEvidence,
  logSearch,
  getUserContext,
  DATING_KEYWORDS,
  EVIDENCE_PER_USER,
} = require('../models/searchModel');
const {
  exactMatch, lookupEntity, findEntityCandidates,
  HIGH_CONFIDENCE_THRESHOLD, SUGGEST_THRESHOLD,
} = require('../services/entityLookupService');
const { resolveVenueToCity } = require('../services/venueLocationService');
const logger = require('../utils/logger');

// Trọng số ưu tiên entity cụ thể so với ngữ nghĩa chung khi cả hai cùng có.
const W_ENTITY  = 0.7;
const W_GENERAL = 0.3;

/**
 * Query Builder — biến specific entity thành query vector (3 nhánh) + gợi ý alias.
 *   1. Exact match (canonical_name / aliases) → embed canonical_name (chắc chắn)
 *   2. Vector match ≥ 0.8 → embed canonical + auto-save alias nền (tự tin)
 *   3. Vùng xám 0.6–0.8 → embed THẲNG entity (an toàn) + trả suggestion để user confirm;
 *      < 0.6 → embed thẳng + fire-and-forget lookupEntity (Wikipedia tự học entity mới)
 * Trả về { vec: number[]|null, suggestion: {keyword, candidates[]}|null }.
 */
async function buildEntityVector(criteria) {
  const name = criteria.entity_name;
  if (!name) return { vec: null, suggestion: null };

  // Nhánh 1 — Tier-1 exact match trên canonical name, rồi từng alias keyword
  for (const term of [name, ...(criteria.entity_keywords ?? [])]) {
    const hit = await exactMatch(term, null);
    if (hit) {
      logger.debug({ term, canonical: hit.canonical_name }, 'QueryBuilder: exact → canonical');
      return { vec: await embedText(hit.canonical_name), suggestion: null };
    }
  }

  // Chưa exact — xem ứng viên vector gần nhất
  const cands = await findEntityCandidates(name, criteria.entity_type || null, 3);
  const top = cands[0];

  // Nhánh 2 — tự tin: embed canonical, alias auto-save do lookupEntity xử lý nền
  if (top && top.similarity >= HIGH_CONFIDENCE_THRESHOLD) {
    logger.debug({ name, canonical: top.canonical_name, sim: top.similarity }, 'QueryBuilder: confident vector → canonical');
    lookupEntity(name, criteria.entity_type || null).catch(() => {});
    return { vec: await embedText(top.canonical_name), suggestion: null };
  }

  // Nhánh 3 — embed thẳng entity (an toàn, không đoán bừa canonical)
  const vec = await embedText(name);

  const greyZone = cands.filter(c => c.similarity >= SUGGEST_THRESHOLD);
  if (greyZone.length) {
    // Vùng xám: hỏi user "ý bạn là …?" — KHÔNG tự lưu alias
    logger.debug({ name, candidates: greyZone.map(c => c.canonical_name) }, 'QueryBuilder: grey-zone suggestion');
    return {
      vec,
      suggestion: {
        keyword:    name,
        candidates: greyZone.map(c => ({ entity_id: c.entity_id, canonical_name: c.canonical_name })),
      },
    };
  }

  // Không có ứng viên nào gần: entity có thể là proper noun mới → tự học nền qua Wikipedia
  lookupEntity(name, criteria.entity_type || null)
    .catch(err => logger.warn({ err, name }, 'QueryBuilder: background entity self-learn failed'));
  logger.debug({ name }, 'QueryBuilder: entity unknown → embed directly');
  return { vec, suggestion: null };
}

/** Ngữ nghĩa chung từ interests + skills (nhánh 3). Trả về number[] hoặc null. */
async function buildGeneralVector(criteria) {
  const terms = [...(criteria.interests ?? []), ...(criteria.skills ?? [])];
  return terms.length ? embedText(terms.join(', ')) : null;
}

/**
 * Merge evidence của 2 lượt retrieval (giữ entry có similarity cao hơn),
 * sắp giảm dần, cắt còn EVIDENCE_PER_USER.
 * Key: profile là 1 entry/user; post đã gộp theo topic ở SQL nên key theo topic.
 */
function evidenceKey(ev) {
  return ev.source_type === 'user_profile' ? 'profile' : `post|${ev.topic ?? ''}`;
}

function mergeEvidence(a, b) {
  const byKey = new Map();
  for (const ev of [...(a ?? []), ...(b ?? [])]) {
    const key  = evidenceKey(ev);
    const prev = byKey.get(key);
    if (!prev || (ev.similarity ?? 0) > (prev.similarity ?? 0)) byKey.set(key, ev);
  }
  return Array.from(byKey.values())
    .sort((x, y) => (y.similarity ?? 0) - (x.similarity ?? 0))
    .slice(0, EVIDENCE_PER_USER);
}

/**
 * Merge 2 tập kết quả theo user.id với trọng số ưu tiên entity.
 * score cuối = W_ENTITY×entity_score + W_GENERAL×general_score (thiếu vế nào = 0).
 * Sắp giảm dần theo score.
 */
function mergeWeighted(entitySet, generalSet) {
  const map = new Map();

  for (const user of entitySet) {
    map.set(user.id, { ...user, score: W_ENTITY * user.score });
  }
  for (const user of generalSet) {
    if (map.has(user.id)) {
      const merged = map.get(user.id);
      merged.score += W_GENERAL * user.score;
      merged.match_evidence = mergeEvidence(merged.match_evidence, user.match_evidence);
    } else {
      map.set(user.id, { ...user, score: W_GENERAL * user.score });
    }
  }

  return Array.from(map.values()).sort((a, b) => b.score - a.score);
}

/**
 * Gom mọi keyword hiển thị được từ criteria — dùng để quét chunk content
 * tìm matched_terms và để match tên/tags community.
 */
function collectCriteriaTerms(criteria) {
  const terms = new Set();
  if (criteria.entity_name) terms.add(criteria.entity_name);
  for (const t of criteria.entity_keywords ?? []) terms.add(t);
  for (const group of criteria.interest_groups ?? []) {
    for (const t of group ?? []) terms.add(t);
  }
  for (const t of criteria.skills ?? []) terms.add(t);
  for (const t of criteria.bio_keywords ?? []) terms.add(t);
  for (const t of criteria.job_title_keywords ?? []) terms.add(t);
  return Array.from(terms).filter(t => typeof t === 'string' && t.trim().length >= 2);
}

/**
 * Biến evidence thô (chunk + community) thành match_evidence gửi client:
 * quét content (bản EN) tìm matched_terms rồi BỎ content/chunk_id khỏi response,
 * map source_type → type gọn, chèn community, cắt còn EVIDENCE_PER_USER.
 * Mutate trực tiếp từng user trong mảng.
 */
function finalizeEvidence(users, terms, communityByUser) {
  for (const user of users) {
    const chunkEv = (user.match_evidence ?? []).map(ev => {
      const content = (ev.content ?? '').toLowerCase();
      const matched = terms.filter(t => content.includes(t.toLowerCase()));
      return {
        type:           ev.source_type === 'user_profile' ? 'profile' : 'post',
        topic:          ev.topic ?? null,
        similarity:     ev.similarity ?? null,
        matched_terms:  matched.slice(0, 3),
        post_count:     ev.post_count ?? null,
        latest_post_at: ev.latest_post_at ?? null,
        oldest_post_at: ev.oldest_post_at ?? null,
      };
    });

    const commEv = (communityByUser.get(user.id) ?? []).map(name => ({
      type:           'community',
      topic:          null,
      similarity:     null,
      matched_terms:  [],
      post_count:     null,
      latest_post_at: null,
      oldest_post_at: null,
      community_name: name,
    }));

    // Chừa chỗ cho community (tối đa 2) nhưng chunk trúng vẫn đứng trước
    const chunkSlots = EVIDENCE_PER_USER - Math.min(commEv.length, 2);
    user.match_evidence = [...chunkEv.slice(0, chunkSlots), ...commEv]
      .slice(0, EVIDENCE_PER_USER);
  }
}

// POST /api/search/ai  (auth required)
// Body: { query, mode?, radiusKm? } — người tìm luôn là user trong JWT
async function aiSearchHandler(req, res, next) {
  try {
    const { query: userQuery, mode, radiusKm } = req.body;
    const currentUserId = req.userId;

    if (!userQuery || typeof userQuery !== 'string' || !userQuery.trim()) {
      return res.status(400).json({ status: 'error', message: 'query is required' });
    }

    // Step 1: LLM extracts hard filters + display criteria
    const criteria = await extractSearchCriteria(userQuery.trim(), mode ?? null);

    // Step 1.5: Venue geocoding for location/radius filter
    let searchCoords = null;
    if (criteria.place_name && !criteria.location) {
      const geocoded = await resolveVenueToCity(criteria.place_name);
      if (geocoded) {
        criteria.location = geocoded.provinceName;
        searchCoords      = { lat: geocoded.lat, lng: geocoded.lng };
      } else {
        criteria.tips += ` 📍 Mình không xác định được "${criteria.place_name}" ở thành phố nào — thêm tên tỉnh/thành để tìm chuẩn hơn nhé!`;
      }
    } else if (criteria.location && radiusKm) {
      const geocoded = await resolveVenueToCity(criteria.location);
      if (geocoded) searchCoords = { lat: geocoded.lat, lng: geocoded.lng };
    }

    // Step 1.6: Fetch searcher's gender for dating intent filter
    let currentUserGender = null;
    if (currentUserId) {
      const ctx = await getUserContext(currentUserId);
      currentUserGender = ctx?.gender ?? null;
    }

    // Step 2: Query Builder — entity vector (+ alias suggestion) và general vector, song song
    const [entityResult, generalVec] = await Promise.all([
      buildEntityVector(criteria),
      buildGeneralVector(criteria),
    ]);
    const entityVec         = entityResult.vec;
    const entitySuggestions = entityResult.suggestion ? [entityResult.suggestion] : [];

    // Step 2.5: Fallback — criteria không ra vector nào, embed intent tiếng Anh đã normalize
    let fallbackVec = null;
    if (!entityVec && !generalVec) {
      fallbackVec = await embedText(criteria.intent_en || userQuery.trim());
      if (!fallbackVec) {
        logSearch(userQuery.trim(), mode ?? null).catch(() => {});
        return res.json({ data: [], criteria, reasoning: criteria.reasoning, tips: criteria.tips, entity_suggestions: entitySuggestions });
      }
    }

    // Step 3: Detect dating intent (heuristic fallback khi prompt không nói rõ giới)
    const hasDatingIntent = Array.isArray(criteria.bio_keywords) &&
      criteria.bio_keywords.some(kw => DATING_KEYWORDS.has(kw.toLowerCase?.() ?? kw));

    // Step 4: Shared filter params applied to every vectorSearch call
    const baseParams = {
      mode:             mode ?? criteria.mode,
      location:         criteria.location,
      targetGender:     criteria.target_gender ?? null,
      targetAgeMin:     criteria.target_age_min ?? null,
      targetAgeMax:     criteria.target_age_max ?? null,
      hasDatingIntent,
      currentUserGender,
      searchCoords,
      radiusKm:         radiusKm ?? null,
      excludeUserId:    currentUserId ?? null,
      threshold:        0.6, // threshold cấp chunk (thiết kế chunk-based)
    };

    const hasInterestGroups = Array.isArray(criteria.interest_groups) &&
      criteria.interest_groups.length > 0;

    // Step 5: Run searches in parallel, then weighted-merge (ưu tiên entity)
    let users;

    if (fallbackVec) {
      users = await vectorSearch({
        ...baseParams,
        queryVector:    fallbackVec,
        interestGroups: hasInterestGroups ? criteria.interest_groups : null,
      });
    } else {
      const [entityResults, generalResults] = await Promise.all([
        entityVec
          ? vectorSearch({ ...baseParams, queryVector: entityVec, interestGroups: null })
          : Promise.resolve([]),
        generalVec
          ? vectorSearch({ ...baseParams, queryVector: generalVec, interestGroups: hasInterestGroups ? criteria.interest_groups : null })
          : Promise.resolve([]),
      ]);

      users = mergeWeighted(entityResults, generalResults);
    }

    // Step 6: Mini-CV evidence — matched terms trong chunk + community đã tham gia
    const terms = collectCriteriaTerms(criteria);
    let communityByUser = new Map();
    try {
      communityByUser = await findCommunityEvidence(users.map(u => u.id), terms);
    } catch (err) {
      logger.warn({ err }, 'Community evidence lookup failed — skipping');
    }
    finalizeEvidence(users, terms, communityByUser);

    logSearch(userQuery.trim(), mode ?? null).catch(err =>
      logger.warn({ err }, 'Failed to log search query')
    );

    res.json({
      data:      users,
      criteria,
      reasoning: criteria.reasoning,
      tips:      criteria.tips,
      entity_suggestions: entitySuggestions, // vùng xám: "ý bạn là …?" để user confirm
    });
  } catch (err) {
    next(err);
  }
}

module.exports = { aiSearchHandler };
