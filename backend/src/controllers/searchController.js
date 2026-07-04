const { extractSearchCriteria, embedText } = require('../services/aiService');
const {
  vectorSearch,
  logSearch,
  getUserContext,
  DATING_KEYWORDS,
} = require('../models/searchModel');
const { resolveVenueToCity } = require('../services/venueLocationService');
const logger = require('../utils/logger');

/**
 * Build entity and interest query vectors from extracted criteria in parallel.
 * Returns { entityVec, interestVec } — either may be null if criteria is absent.
 */
async function buildQueryVectors(criteria) {
  const entityText = criteria.entity_keywords?.length
    ? criteria.entity_keywords.join(' ')
    : null;

  const interestTerms = [
    ...(criteria.interests ?? []),
    ...(criteria.skills   ?? []),
  ];
  const interestText = interestTerms.length ? interestTerms.join(', ') : null;

  const [entityVec, interestVec] = await Promise.all([
    entityText   ? embedText(entityText)   : Promise.resolve(null),
    interestText ? embedText(interestText) : Promise.resolve(null),
  ]);

  return { entityVec, interestVec };
}

/**
 * Merge two result sets by user.id.
 * Users in both sets get combined_score = entity_score + interest_score.
 * Sorted by combined_score descending.
 */
function mergeResults(setA, setB) {
  const map = new Map();

  for (const user of setA) {
    map.set(user.id, { ...user, combined_score: user.score });
  }

  for (const user of setB) {
    if (map.has(user.id)) {
      map.get(user.id).combined_score += user.score;
    } else {
      map.set(user.id, { ...user, combined_score: user.score });
    }
  }

  return Array.from(map.values())
    .sort((a, b) => b.combined_score - a.combined_score);
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

    // Step 2: Build query vectors from extracted criteria (parallel)
    const { entityVec, interestVec } = await buildQueryVectors(criteria);

    // Step 2.5: Fallback — criteria yielded nothing, embed raw query
    let fallbackVec = null;
    if (!entityVec && !interestVec) {
      fallbackVec = await embedText(userQuery.trim());
      if (!fallbackVec) {
        logSearch(userQuery.trim(), mode ?? null).catch(() => {});
        return res.json({ data: [], criteria, reasoning: criteria.reasoning, tips: criteria.tips });
      }
    }

    // Step 3: Detect dating intent
    const hasDatingIntent = Array.isArray(criteria.bio_keywords) &&
      criteria.bio_keywords.some(kw => DATING_KEYWORDS.has(kw.toLowerCase?.() ?? kw));

    // Step 4: Shared filter params applied to every vectorSearch call
    const baseParams = {
      mode:             mode ?? criteria.mode,
      location:         criteria.location,
      hasDatingIntent,
      currentUserGender,
      searchCoords,
      radiusKm:         radiusKm ?? null,
      excludeUserId:    currentUserId ?? null,
      threshold:        0.6, // threshold cấp chunk (thiết kế chunk-based)
    };

    const hasInterestGroups = Array.isArray(criteria.interest_groups) &&
      criteria.interest_groups.length > 0;

    // Step 5: Run searches in parallel, then merge
    let users;

    if (fallbackVec) {
      users = await vectorSearch({
        ...baseParams,
        queryVector:    fallbackVec,
        interestGroups: hasInterestGroups ? criteria.interest_groups : null,
      });
    } else {
      const [entityResults, interestResults] = await Promise.all([
        entityVec
          ? vectorSearch({ ...baseParams, queryVector: entityVec, interestGroups: null })
          : Promise.resolve([]),
        interestVec
          ? vectorSearch({ ...baseParams, queryVector: interestVec, interestGroups: hasInterestGroups ? criteria.interest_groups : null })
          : Promise.resolve([]),
      ]);

      users = mergeResults(entityResults, interestResults);
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
