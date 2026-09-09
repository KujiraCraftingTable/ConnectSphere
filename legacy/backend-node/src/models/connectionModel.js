const { query } = require('../config/db');

// All accepted connection_ids for a user (regardless of requester/addressee direction,
// not filtered by mode — used for jobs/tasks that need the user's "full friend list",
// e.g. birthday notification).
async function getConnectionIds(userId) {
  const { rows } = await query(
    `SELECT DISTINCT
       CASE WHEN c.requester_id = $1 THEN c.addressee_id ELSE c.requester_id END AS connection_id
     FROM connections c
     WHERE c.status = 'accepted' AND (c.requester_id = $1 OR c.addressee_id = $1)`,
    [userId]
  );
  return rows.map((r) => r.connection_id);
}

module.exports = { getConnectionIds };
