const { query }      = require('../config/db');
const analyticsModel = require('../models/analyticsModel');
const communityModel = require('../models/communityModel');

function clientError(message, status = 400) {
  const err = new Error(message);
  err.status = status;
  throw err;
}

// Compute and store today's snapshot for one community
async function recordDailySnapshot(communityId) {
  const today = new Date().toISOString().split('T')[0]; // YYYY-MM-DD

  const { rows } = await query(
    `SELECT
       (SELECT COUNT(*) FROM community_members
        WHERE community_id = $1)                               AS member_count,
       (SELECT COUNT(*) FROM posts
        WHERE community_id = $1)                               AS post_count,
       (SELECT COUNT(*) FROM community_members
        WHERE community_id = $1 AND joined_at >= CURRENT_DATE) AS new_members,
       (SELECT COUNT(*) FROM posts
        WHERE community_id = $1 AND created_at >= CURRENT_DATE) AS new_posts,
       (SELECT COUNT(DISTINCT author_id) FROM posts
        WHERE community_id = $1
          AND created_at >= NOW() - INTERVAL '24 hours')       AS active_members`,
    [communityId]
  );

  const s = rows[0];
  return analyticsModel.upsertDailySnapshot(communityId, today, {
    memberCount:   parseInt(s.member_count,   10),
    postCount:     parseInt(s.post_count,     10),
    newMembers:    parseInt(s.new_members,    10),
    newPosts:      parseInt(s.new_posts,      10),
    activeMembers: parseInt(s.active_members, 10),
  });
}

// Build and return analytics summary (admin only)
async function getAnalyticsSummary(communityId, requesterId, days = 30) {
  const parsedDays = Math.min(parseInt(days, 10) || 30, 90);

  // Permission check
  const membership = await communityModel.isMember(communityId, requesterId);
  if (!membership || membership.role !== 'admin') {
    clientError('Only admins can view analytics', 403);
  }

  const snapshots = await analyticsModel.getAnalytics(communityId, { days: parsedDays });
  const community = await communityModel.getCommunityById(communityId);

  // Growth rates compared to oldest snapshot in the range
  const first = snapshots[0];
  const last  = snapshots[snapshots.length - 1];

  const memberGrowthRate = first?.member_count > 0
    ? ((last.member_count - first.member_count) / first.member_count) * 100 : 0;
  const postGrowthRate = first?.post_count > 0
    ? ((last.post_count - first.post_count) / first.post_count) * 100 : 0;

  // Top 5 posts in the period by engagement
  const { rows: topPosts } = await query(
    `SELECT p.id, p.content, p.like_count, p.comment_count, p.created_at,
            json_build_object(
              'id',           u.id,
              'username',     u.username,
              'display_name', u.display_name,
              'avatar_color', u.avatar_color
            ) AS author
     FROM posts p
     JOIN users u ON u.id = p.author_id
     WHERE p.community_id = $1
       AND p.created_at >= NOW() - ($2 || ' days')::INTERVAL
     ORDER BY (p.like_count + p.comment_count) DESC
     LIMIT 5`,
    [communityId, String(parsedDays)]
  );

  return {
    totalMembers:     community?.member_count || 0,
    totalPosts:       community?.post_count   || 0,
    memberGrowthRate: Math.round(memberGrowthRate * 100) / 100,
    postGrowthRate:   Math.round(postGrowthRate   * 100) / 100,
    dailySnapshots:   snapshots,
    topPosts,
  };
}

// Run snapshot for all communities (called by daily cron job)
async function scheduleAllSnapshots() {
  const { rows } = await query(`SELECT id FROM communities`);
  for (const { id } of rows) {
    try { await recordDailySnapshot(id); } catch (_) { /* continue on error */ }
  }
}

module.exports = { recordDailySnapshot, getAnalyticsSummary, scheduleAllSnapshots };
