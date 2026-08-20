const { extractSearchCriteria, embedText } = require('../services/aiService');
const {
  vectorSearch,
  logSearch,
  getUserContext,
  DATING_KEYWORDS,
} = require('../models/searchModel');
const { exactMatch, lookupEntity } = require('../services/entityLookupService');
const { resolveVenueToCity } = require('../services/venueLocationService');
const logger = require('../utils/logger');

// Trọng số ưu tiên entity cụ thể so với ngữ nghĩa chung khi cả hai cùng có.
const W_ENTITY  = 0.7;
const W_GENERAL = 0.3;

/**
 * Query Builder — biến specific entity thành 1 query vector (3 nhánh):
 *   1. Entity có trong interest_entities (canonical_name / aliases) → embed canonical_name
 *      (canonical được đính vào chunk text nên hai vế gặp nhau trong không gian vector)
 *   2. Entity chưa có trong DB → embed thẳng entity text, đồng thời fire-and-forget
 *      lookupEntity để Wikipedia/vector tự học, lần sau đã có canonical
 * Trả về number[] hoặc null.
 */
async function buildEntityVector(criteria) {
  const name = criteria.entity_name;
  if (!name) return null;

  // Nhánh 1 — Tier-1 exact match trên canonical name, rồi từng alias keyword
  const candidates = [name, ...(criteria.entity_keywords ?? [])];
  for (const term of candidates) {
    const hit = await exactMatch(term, null);
    if (hit) {
      logger.debug({ term, canonical: hit.canonical_name }, 'QueryBuilder: entity → canonical');
      return embedText(hit.canonical_name);
    }
  }

  // Nhánh 2 — chưa có trong DB: embed trực tiếp + tự học nền (không chặn search)
  lookupEntity(name, criteria.entity_type || null)
    .catch(err => logger.warn({ err, name }, 'QueryBuilder: background entity self-learn failed'));
  logger.debug({ name }, 'QueryBuilder: entity not in DB → embed directly');
  return embedText(name);
}

/** Ngữ nghĩa chung từ interests + skills (nhánh 3). Trả về number[] hoặc null. */
async function buildGeneralVector(criteria) {
  const terms = [...(criteria.interests ?? []), ...(criteria.skills ?? [])];
  return terms.length ? embedText(terms.join(', ')) : null;
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
      map.get(user.id).score += W_GENERAL * user.score;
    } else {
      map.set(user.id, { ...user, score: W_GENERAL * user.score });
    }
  }

  return Array.from(map.values()).sort((a, b) => b.score - a.score);
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

    // Step 2: Query Builder — entity vector (nhánh 1/2) + general vector (nhánh 3), song song
    const [entityVec, generalVec] = await Promise.all([
      buildEntityVector(criteria),
      buildGeneralVector(criteria),
    ]);

    // Step 2.5: Fallback — criteria không ra vector nào, embed intent tiếng Anh đã normalize
    let fallbackVec = null;
    if (!entityVec && !generalVec) {
      fallbackVec = await embedText(criteria.intent_en || userQuery.trim());
      if (!fallbackVec) {
        logSearch(userQuery.trim(), mode ?? null).catch(() => {});
        return res.json({ data: [], criteria, reasoning: criteria.reasoning, tips: criteria.tips });
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

    logSearch(userQuery.trim(), mode ?? null).catch(err =>
      logger.warn({ err }, 'Failed to log search query')
    );

    res.json({
      data:      users,
      criteria,
      reasoning: criteria.reasoning,
      tips:      criteria.tips,
    });
  } catch (err) {
    next(err);
  }
}

module.exports = { aiSearchHandler };
