const { query } = require('../config/db');

// Insert or update today's snapshot (idempotent — safe to re-run)
async function upsertDailySnapshot(communityId, date, {
  memberCount, postCount, newMembers, newPosts, activeMembers,
}) {
  const { rows } = await query(
    `INSERT INTO community_analytics
       (community_id, snapshot_date, member_count, post_count,
        new_members, new_posts, active_members)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (community_id, snapshot_date)
     DO UPDATE SET
       member_count   = $3,
       post_count     = $4,
       new_members    = $5,
       new_posts      = $6,
       active_members = $7
     RETURNING *`,
    [communityId, date, memberCount, postCount, newMembers, newPosts, activeMembers]
  );
  return rows[0];
}

// Return daily snapshots for the past N days, sorted ascending (for chart)
async function getAnalytics(communityId, { days = 30 } = {}) {
  const safeDays = Math.min(parseInt(days, 10) || 30, 90);
  const { rows } = await query(
    `SELECT snapshot_date, member_count, post_count,
            new_members, new_posts, active_members
     FROM community_analytics
     WHERE community_id = $1
       AND snapshot_date >= CURRENT_DATE - ($2 || ' days')::INTERVAL
     ORDER BY snapshot_date ASC`,
    [communityId, String(safeDays)]
  );
  return rows;
}

module.exports = { upsertDailySnapshot, getAnalytics };
