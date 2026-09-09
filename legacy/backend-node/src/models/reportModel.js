const { query } = require('../config/db');

// Create a new report; enforced UNIQUE constraint prevents duplicates at DB level
async function createReport({ reporterId, targetType, targetId, communityId, reason, detail }) {
  const { rows } = await query(
    `INSERT INTO community_reports
       (reporter_id, target_type, target_id, community_id, reason, detail)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING *`,
    [reporterId, targetType, targetId, communityId, reason, detail || null]
  );
  return rows[0];
}

// Count pending reports for a specific target (used for auto-notify threshold)
async function countPendingReportsForTarget(targetType, targetId) {
  const { rows } = await query(
    `SELECT COUNT(*) FROM community_reports
     WHERE target_type = $1 AND target_id = $2 AND status = 'pending'`,
    [targetType, targetId]
  );
  return parseInt(rows[0].count, 10);
}

// Paginated moderation queue for a community.
// Reporter identity is intentionally NOT included in output (privacy).
async function getReportsByStatus(communityId, status, { limit = 20, offset = 0 } = {}) {
  const params = [communityId, limit, offset];
  let statusFilter = '';
  if (status === 'resolved') {
    // The "Resolved" tab must also surface dismissed reports — resolveReport
    // stores a dismissed report with status 'dismissed', which would otherwise
    // vanish from every tab.
    statusFilter = `AND r.status IN ('resolved', 'dismissed')`;
  } else if (status && status !== 'all') {
    params.push(status);
    statusFilter = `AND r.status = $${params.length}`;
  }

  const { rows } = await query(
    `SELECT
       r.id, r.target_type, r.target_id, r.reason, r.detail,
       r.status, r.created_at,
       CASE WHEN r.target_type = 'post' THEN
         (SELECT p.content FROM posts p WHERE p.id = r.target_id)
       ELSE NULL END AS post_content,
       CASE WHEN r.target_type = 'member' THEN
         json_build_object(
           'id',           u.id,
           'username',     u.username,
           'display_name', u.display_name,
           'avatar_color', u.avatar_color
         )
       ELSE NULL END AS member_info
     FROM community_reports r
     LEFT JOIN users u ON u.id = r.target_id AND r.target_type = 'member'
     WHERE r.community_id = $1 ${statusFilter}
     ORDER BY r.created_at DESC
     LIMIT $2 OFFSET $3`,
    params
  );
  return rows;
}

// Update report status and record who resolved it
async function resolveReport(reportId, resolvedBy, status) {
  const { rows } = await query(
    `UPDATE community_reports
     SET status = $2, resolved_by = $3, resolved_at = NOW()
     WHERE id = $1
     RETURNING *`,
    [reportId, status, resolvedBy]
  );
  return rows[0] || null;
}

// Check if a user has already reported this target (duplicate guard)
async function hasReported(reporterId, targetType, targetId) {
  const { rows } = await query(
    `SELECT id FROM community_reports
     WHERE reporter_id = $1 AND target_type = $2 AND target_id = $3`,
    [reporterId, targetType, targetId]
  );
  return rows[0] || null;
}

// Fetch a single report by ID (for service validation)
async function getReportById(reportId) {
  const { rows } = await query(
    `SELECT * FROM community_reports WHERE id = $1`,
    [reportId]
  );
  return rows[0] || null;
}

// Total pending report count for a community (used for badge)
async function getPendingReportCount(communityId) {
  const { rows } = await query(
    `SELECT COUNT(*) FROM community_reports
     WHERE community_id = $1 AND status = 'pending'`,
    [communityId]
  );
  return parseInt(rows[0].count, 10);
}

module.exports = {
  createReport,
  countPendingReportsForTarget,
  getReportsByStatus,
  resolveReport,
  hasReported,
  getReportById,
  getPendingReportCount,
};
