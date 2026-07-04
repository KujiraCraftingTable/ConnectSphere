const { query } = require('../config/db');

// Fetch user's top interest tags by weight
async function getUserInterests(userId) {
  const { rows } = await query(
    `SELECT tag, weight FROM recommendation_interests
     WHERE user_id = $1
     ORDER BY weight DESC
     LIMIT 20`,
    [userId]
  );
  return rows;
}

// Add or increment interest weight for a tag; cap at 10.0 to prevent runaway values
async function upsertInterest(userId, tag, weightDelta = 1.0) {
  await query(
    `INSERT INTO recommendation_interests (user_id, tag, weight, updated_at)
     VALUES ($1, $2, $3, NOW())
     ON CONFLICT (user_id, tag)
     DO UPDATE SET
       weight     = LEAST(recommendation_interests.weight + $3, 10.0),
       updated_at = NOW()`,
    [userId, tag, weightDelta]
  );
}

// Fetch all tags for a community
async function getCommunityTags(communityId) {
  const { rows } = await query(
    `SELECT tag FROM community_tags WHERE community_id = $1`,
    [communityId]
  );
  return rows.map(r => r.tag);
}

// Replace all tags for a community (delete + insert in one transaction)
async function addTagsToCommunity(communityId, tags) {
  await query(`DELETE FROM community_tags WHERE community_id = $1`, [communityId]);
  if (!tags.length) return;

  const params = [communityId];
  const clauses = tags.map(tag => {
    params.push(tag);
    return `($1, $${params.length})`;
  });
  await query(
    `INSERT INTO community_tags (community_id, tag) VALUES ${clauses.join(', ')} ON CONFLICT DO NOTHING`,
    params
  );
}

// Scored recommendation query — score = overlap×2 + trending×0.5 + log(members)×0.3
async function getRecommendedCommunities(userId, { limit = 10 } = {}) {
  const { rows } = await query(
    `WITH user_tags AS (
       SELECT tag, weight FROM recommendation_interests
       WHERE user_id = $1 ORDER BY weight DESC LIMIT 10
     )
     SELECT
       c.id, c.name, c.description, c.type, c.privacy,
       c.icon_emoji, c.cover_color, c.member_count, c.post_count,
       false AS is_member, NULL::VARCHAR AS role, c.created_at,
       COUNT(DISTINCT ct.tag)::FLOAT                    AS tag_overlap,
       COALESCE(tr.score, 0)                            AS trending_score,
       (COUNT(DISTINCT ct.tag)::FLOAT * 2.0)
         + (COALESCE(tr.score, 0) * 0.5)
         + (LN(GREATEST(c.member_count, 1)) * 0.3)     AS rec_score
     FROM communities c
     JOIN community_tags    ct ON ct.community_id = c.id
     JOIN user_tags         ut ON ut.tag = ct.tag
     LEFT JOIN community_trending tr ON tr.community_id = c.id
     WHERE c.id NOT IN (
       SELECT community_id FROM community_members WHERE user_id = $1
     )
       AND c.privacy = 'public'
     GROUP BY c.id, tr.score
     ORDER BY rec_score DESC
     LIMIT $2`,
    [userId, limit]
  );
  return rows;
}

// Upsert trending score for one community
async function updateTrendingScore(communityId, score) {
  await query(
    `INSERT INTO community_trending (community_id, score, computed_at)
     VALUES ($1, $2, NOW())
     ON CONFLICT (community_id)
     DO UPDATE SET score = $2, computed_at = NOW()`,
    [communityId, score]
  );
}

// Fetch communities by trending score, optionally filtered by type
async function getTrendingCommunities({ type = null, limit = 20 } = {}) {
  const params = [limit];
  let typeFilter = '';
  if (type) {
    params.push(type);
    typeFilter = `AND c.type = $${params.length}`;
  }

  const { rows } = await query(
    `SELECT c.id, c.name, c.description, c.type, c.privacy,
            c.icon_emoji, c.cover_color, c.member_count, c.post_count,
            false AS is_member, NULL::VARCHAR AS role, c.created_at,
            COALESCE(tr.score, 0) AS trending_score
     FROM communities c
     LEFT JOIN community_trending tr ON tr.community_id = c.id
     WHERE c.privacy = 'public' ${typeFilter}
     ORDER BY trending_score DESC, c.member_count DESC
     LIMIT $1`,
    params
  );
  return rows;
}

// Bulk fetch tags for multiple communities (returns { communityId → [tags] })
async function getCommunitiesWithTags(communityIds) {
  if (!communityIds.length) return {};

  const placeholders = communityIds.map((_, i) => `$${i + 1}`).join(', ');
  const { rows } = await query(
    `SELECT community_id, tag FROM community_tags WHERE community_id IN (${placeholders})`,
    communityIds
  );

  const result = {};
  for (const row of rows) {
    if (!result[row.community_id]) result[row.community_id] = [];
    result[row.community_id].push(row.tag);
  }
  return result;
}

module.exports = {
  getUserInterests,
  upsertInterest,
  getCommunityTags,
  addTagsToCommunity,
  getRecommendedCommunities,
  updateTrendingScore,
  getTrendingCommunities,
  getCommunitiesWithTags,
};
