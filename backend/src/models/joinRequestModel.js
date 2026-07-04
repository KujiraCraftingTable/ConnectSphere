const { query } = require('../config/db');

// Create a pending join request; throws if a row already exists (UNIQUE constraint)
async function createRequest(communityId, userId) {
  const { rows } = await query(
    `INSERT INTO community_join_requests (community_id, user_id)
     VALUES ($1, $2)
     RETURNING *`,
    [communityId, userId]
  );
  return rows[0];
}

// Paginated list of pending requests for a community
async function getPendingRequests(communityId, { limit = 20, offset = 0 } = {}) {
  const { rows } = await query(
    `SELECT jr.id, jr.requested_at, jr.status,
            u.id AS user_id, u.username, u.display_name, u.avatar_color
     FROM community_join_requests jr
     JOIN users u ON u.id = jr.user_id
     WHERE jr.community_id = $1 AND jr.status = 'pending'
     ORDER BY jr.requested_at ASC
     LIMIT $2 OFFSET $3`,
    [communityId, limit, offset]
  );
  return rows;
}

// Approve or reject a request; records reviewer and timestamp
async function reviewRequest(requestId, reviewerId, status) {
  const { rows } = await query(
    `UPDATE community_join_requests
     SET status = $2, reviewed_by = $3, reviewed_at = NOW()
     WHERE id = $1
     RETURNING *`,
    [requestId, status, reviewerId]
  );
  return rows[0] || null;
}

// Check for an existing request row (any status) for a community + user pair
async function hasExistingRequest(communityId, userId) {
  const { rows } = await query(
    `SELECT id, status
     FROM community_join_requests
     WHERE community_id = $1 AND user_id = $2`,
    [communityId, userId]
  );
  return rows[0] || null;
}

// Fetch a single request by its ID (for service-layer validation)
async function getRequestById(requestId) {
  const { rows } = await query(
    `SELECT * FROM community_join_requests WHERE id = $1`,
    [requestId]
  );
  return rows[0] || null;
}

module.exports = {
  createRequest,
  getPendingRequests,
  reviewRequest,
  hasExistingRequest,
  getRequestById,
};
