const { query }             = require('../config/db');
const recommendationModel   = require('../models/recommendationModel');
const communityModel        = require('../models/communityModel');

function clientError(message, status = 400) {
  const err = new Error(message);
  err.status = status;
  throw err;
}

// Rebuild user interest weights from their joined communities' tags.
// Clears first so this is a true rebuild — without it, upsertInterest's
// `weight = LEAST(weight + delta, 10)` accumulated on every join/leave until
// every tag saturated at 10.0 and the ordering became meaningless.
async function buildUserInterests(userId) {
  await recommendationModel.clearInterests(userId);

  const myCommunities = await communityModel.getCommunitiesByUser(userId);
  if (!myCommunities.length) return;

  const tagsMap = await recommendationModel.getCommunitiesWithTags(
    myCommunities.map(c => c.id)
  );

  for (const tags of Object.values(tagsMap)) {
    for (const tag of tags) {
      await recommendationModel.upsertInterest(userId, tag, 1.0);
    }
  }
}

// Return recommended communities; falls back to trending if user has no interests
async function getRecommendations(userId, { limit = 10 } = {}) {
  const interests = await recommendationModel.getUserInterests(userId);
  if (!interests.length) {
    return recommendationModel.getTrendingCommunities({ limit });
  }
  return recommendationModel.getRecommendedCommunities(userId, { limit });
}

// Compute and cache trending score for one community.
// Each metric is an independent scalar subquery — joining posts + members +
// posts in one FROM produced a cartesian product that inflated the non-DISTINCT
// post count by members × total_posts.
async function computeTrendingScore(communityId) {
  const { rows } = await query(
    `SELECT
       (SELECT COUNT(*) FROM posts
          WHERE community_id = $1 AND created_at >= NOW() - INTERVAL '24 hours')            AS new_posts_24h,
       (SELECT COUNT(*) FROM community_members
          WHERE community_id = $1 AND joined_at  >= NOW() - INTERVAL '24 hours')            AS new_members_24h,
       (SELECT COUNT(DISTINCT author_id) FROM posts
          WHERE community_id = $1 AND created_at >= NOW() - INTERVAL '24 hours')            AS active_members_24h`,
    [communityId]
  );

  const { new_posts_24h, new_members_24h, active_members_24h } = rows[0];
  const score = (parseInt(new_posts_24h,     10) * 3)
              + (parseInt(new_members_24h,   10) * 5)
              + (parseInt(active_members_24h, 10) * 2);

  await recommendationModel.updateTrendingScore(communityId, score);
  return score;
}

// Recompute trending scores for ALL communities (called by hourly cron)
async function computeAllTrendingScores() {
  const { rows } = await query(`SELECT id FROM communities`);
  for (const { id } of rows) {
    try { await computeTrendingScore(id); } catch (_) { /* continue */ }
  }
}

// Trending communities list
async function getTrending({ type = null, limit = 20 } = {}) {
  return recommendationModel.getTrendingCommunities({ type, limit });
}

// Combined discover payload: trending + recommended
async function getDiscover(userId, { type = null } = {}) {
  const [trending, recommended] = await Promise.all([
    recommendationModel.getTrendingCommunities({ type, limit: 10 }),
    getRecommendations(userId, { limit: 10 }),
  ]);
  return { trending, recommended };
}

// Set (replace) tags on a community — admin only
async function setTags(communityId, tags, requesterId) {
  const VALID_TAG_RE = /^[a-z0-9_-]+$/;
  const MAX_TAGS = 10;

  if (!Array.isArray(tags)) clientError('tags must be an array');
  if (tags.length > MAX_TAGS) clientError(`Maximum ${MAX_TAGS} tags allowed`);

  const membership = await communityModel.isMember(communityId, requesterId);
  if (!membership || membership.role !== 'admin') {
    clientError('Only admins can manage community tags', 403);
  }

  const cleaned = [...new Set(
    tags.map(t => t.trim().toLowerCase()).filter(t => t && VALID_TAG_RE.test(t))
  )];

  await recommendationModel.addTagsToCommunity(communityId, cleaned);
  return cleaned;
}

// Non-blocking: schedule an interest rebuild after join/leave/post events
function scheduleInterestRebuild(userId) {
  setImmediate(async () => {
    try { await buildUserInterests(userId); } catch (_) { /* silent */ }
  });
}

module.exports = {
  buildUserInterests,
  getRecommendations,
  computeTrendingScore,
  computeAllTrendingScores,
  getTrending,
  getDiscover,
  setTags,
  scheduleInterestRebuild,
};
