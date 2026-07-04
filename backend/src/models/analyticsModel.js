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

// Communities ranked by recent member growth (used for top communities list)
async function getTopCommunities({ type = null, limit = 10 } = {}) {
  const params = [limit];
  let typeFilter = '';
  if (type) {
    params.push(type);
    typeFilter = `AND c.type = $${params.length}`;
  }

  const { rows } = await query(
    `SELECT c.id, c.name, c.icon_emoji, c.cover_color, c.member_count,
            COALESCE(SUM(a.new_members), 0) AS recent_growth
     FROM communities c
     LEFT JOIN community_analytics a
       ON a.community_id = c.id
       AND a.snapshot_date >= CURRENT_DATE - INTERVAL '7 days'
     WHERE 1=1 ${typeFilter}
     GROUP BY c.id
     ORDER BY recent_growth DESC, c.member_count DESC
     LIMIT $1`,
    params
  );
  return rows;
}

module.exports = { upsertDailySnapshot, getAnalytics, getTopCommunities };
