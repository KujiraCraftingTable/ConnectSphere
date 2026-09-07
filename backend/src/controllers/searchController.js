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

// Weights that prioritize the specific entity over general semantics when both are present.
const W_ENTITY  = 0.7;
const W_GENERAL = 0.3;

/**
 * Query Builder — turns a specific entity into a query vector (3 branches) + an alias suggestion.
 *   1. Exact match (canonical_name / aliases) → embed canonical_name (certain)
 *   2. Vector match ≥ 0.8 → embed canonical + auto-save alias in the background (confident)
 *   3. Grey zone 0.6–0.8 → embed the entity DIRECTLY (safe) + return a suggestion for the user to confirm;
 *      < 0.6 → embed directly + fire-and-forget lookupEntity (Wikipedia self-learns the new entity)
 * Returns { vec: number[]|null, suggestion: {keyword, candidates[]}|null }.
 */
async function buildEntityVector(criteria) {
  const name = criteria.entity_name;
  if (!name) return { vec: null, suggestion: null };

  // Branch 1 — Tier-1 exact match on canonical name, then each alias keyword
  for (const term of [name, ...(criteria.entity_keywords ?? [])]) {
    const hit = await exactMatch(term, null);
    if (hit) {
      logger.debug({ term, canonical: hit.canonical_name }, 'QueryBuilder: exact → canonical');
      return { vec: await embedText(hit.canonical_name), suggestion: null };
    }
  }

  // No exact match — look at the nearest vector candidates
  const cands = await findEntityCandidates(name, criteria.entity_type || null, 3);
  const top = cands[0];

  // Branch 2 — confident: embed canonical, alias auto-save handled in the background by lookupEntity
  if (top && top.similarity >= HIGH_CONFIDENCE_THRESHOLD) {
    logger.debug({ name, canonical: top.canonical_name, sim: top.similarity }, 'QueryBuilder: confident vector → canonical');
    lookupEntity(name, criteria.entity_type || null).catch(() => {});
    return { vec: await embedText(top.canonical_name), suggestion: null };
  }

  // Branch 3 — embed the entity directly (safe, no guessing at canonical)
  const vec = await embedText(name);

  const greyZone = cands.filter(c => c.similarity >= SUGGEST_THRESHOLD);
  if (greyZone.length) {
    // Grey zone: ask the user "did you mean …?" — do NOT auto-save the alias
    logger.debug({ name, candidates: greyZone.map(c => c.canonical_name) }, 'QueryBuilder: grey-zone suggestion');
    return {
      vec,
      suggestion: {
        keyword:    name,
        candidates: greyZone.map(c => ({ entity_id: c.entity_id, canonical_name: c.canonical_name })),
      },
    };
  }

  // No close candidates: the entity might be a new proper noun → self-learn in the background via Wikipedia
  lookupEntity(name, criteria.entity_type || null)
    .catch(err => logger.warn({ err, name }, 'QueryBuilder: background entity self-learn failed'));
  logger.debug({ name }, 'QueryBuilder: entity unknown → embed directly');
  return { vec, suggestion: null };
}

/** General semantics from interests + skills (branch 3). Returns number[] or null. */
async function buildGeneralVector(criteria) {
  const terms = [...(criteria.interests ?? []), ...(criteria.skills ?? [])];
  return terms.length ? embedText(terms.join(', ')) : null;
}

/**
 * Merge evidence from the two retrieval passes (keep the entry with the higher
 * similarity), sort descending, trim to EVIDENCE_PER_USER.
 * Key: profile is 1 entry/user; posts are already grouped by topic in SQL, so key by topic.
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
 * Merge the two result sets by user.id with weights that prioritize entity matches.
 * final score = W_ENTITY×entity_score + W_GENERAL×general_score (missing side = 0).
 * Sorted descending by score.
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
 * Collect every displayable keyword from criteria — used to scan chunk content
 * for matched_terms and to match community names/tags.
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
 * Turns raw evidence (chunk + community) into the match_evidence sent to the client:
 * scans content (the EN version) for matched_terms then STRIPS content/chunk_id from
 * the response, maps source_type → a compact type, inserts community, trims to
 * EVIDENCE_PER_USER. Mutates each user in the array directly.
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

    // Reserve slots for community (max 2) but matched chunks still come first
    const chunkSlots = EVIDENCE_PER_USER - Math.min(commEv.length, 2);
    user.match_evidence = [...chunkEv.slice(0, chunkSlots), ...commEv]
      .slice(0, EVIDENCE_PER_USER);
  }
}

/**
 * Geocode a venue/place name or city name into search coordinates. Returns a
 * plain result rather than mutating `criteria` directly, so this can run
 * concurrently with Query Builder below — its output (searchCoords / the
 * resolved location) isn't actually consumed until baseParams, well after
 * Query Builder already runs, so nothing requires it to block first.
 */
async function resolveGeocode(criteria, radiusKm) {
  if (criteria.place_name && !criteria.location) {
    const geocoded = await resolveVenueToCity(criteria.place_name);
    if (geocoded) {
      return { location: geocoded.provinceName, searchCoords: { lat: geocoded.lat, lng: geocoded.lng }, unresolvedPlace: null };
    }
    // Venue didn't resolve — the location filter silently doesn't apply, so the
    // user needs telling; surfaced as a warning rather than failing the search.
    logger.debug({ placeName: criteria.place_name }, 'Search: venue could not be geocoded');
    return { location: null, searchCoords: null, unresolvedPlace: criteria.place_name };
  }
  if (criteria.location && radiusKm) {
    const geocoded = await resolveVenueToCity(criteria.location);
    if (geocoded) return { location: null, searchCoords: { lat: geocoded.lat, lng: geocoded.lng }, unresolvedPlace: null };
  }
  return { location: null, searchCoords: null, unresolvedPlace: null };
}

// POST /api/search/ai  (auth required)
// Body: { query, mode?, radiusKm? } — the searcher is always the user from the JWT
async function aiSearchHandler(req, res, next) {
  try {
    const { query: userQuery, mode, radiusKm } = req.body;
    const currentUserId = req.userId;

    if (!userQuery || typeof userQuery !== 'string' || !userQuery.trim()) {
      return res.status(400).json({ status: 'error', message: 'query is required' });
    }

    // Step 1: LLM extracts hard filters + display criteria
    const criteria = await extractSearchCriteria(userQuery.trim(), mode ?? null);

    // Step 2: Geocoding, searcher context, and Query Builder vectors — none of
    // these depend on each other's output (they only converge below, in
    // baseParams), so they run concurrently instead of one after another.
    const parallelStart = Date.now();
    const [geocodeResult, ctx, entityResult, generalVec] = await Promise.all([
      resolveGeocode(criteria, radiusKm),
      currentUserId ? getUserContext(currentUserId) : Promise.resolve(null),
      buildEntityVector(criteria),
      buildGeneralVector(criteria),
    ]);
    logger.info({ durationMs: Date.now() - parallelStart }, 'AI search: geocode/context/QueryBuilder done');

    let searchCoords = null;
    if (geocodeResult.location)     criteria.location = geocodeResult.location;
    if (geocodeResult.searchCoords) searchCoords = geocodeResult.searchCoords;

    // Warnings = "part of your query couldn't be understood or applied". Only
    // populated on a concrete failure, never generic advice — an empty array
    // means the client shows nothing. Structured codes (not prose) so iOS
    // renders them through its own EN/VI localization.
    const warnings = [];
    if (geocodeResult.unresolvedPlace) {
      warnings.push({ code: 'venue_unresolved', value: geocodeResult.unresolvedPlace });
    }

    const currentUserGender = ctx?.gender ?? null;

    const entityVec         = entityResult.vec;
    const entitySuggestions = entityResult.suggestion ? [entityResult.suggestion] : [];

    // Step 2.5: Fallback — criteria produced no vector at all, embed the normalized English intent
    let fallbackVec = null;
    if (!entityVec && !generalVec) {
      // Nothing concrete was extracted (no entity, no interests, no skills) —
      // the search still runs on raw intent, but tell the user why it's vague.
      warnings.push({ code: 'query_unclear', value: null });
      fallbackVec = await embedText(criteria.intent_en || userQuery.trim());
      if (!fallbackVec) {
        logSearch(userQuery.trim(), mode ?? null).catch(() => {});
        return res.json({ data: [], criteria, entity_suggestions: entitySuggestions, warnings });
      }
    }

    // Step 3: Detect dating intent (heuristic fallback when the prompt doesn't specify gender)
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
      threshold:        0.6, // chunk-level threshold (chunk-based design)
    };

    const hasInterestGroups = Array.isArray(criteria.interest_groups) &&
      criteria.interest_groups.length > 0;

    // Step 5: Run searches in parallel, then weighted-merge (prioritizing entity)
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

    // Step 6: Mini-CV evidence — matched terms within chunks + communities the user has joined
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
      entity_suggestions: entitySuggestions, // grey zone: "did you mean …?" for the user to confirm
      warnings,                              // only populated when the AI couldn't understand/apply some part of the query
    });
  } catch (err) {
    next(err);
  }
}

module.exports = { aiSearchHandler };
