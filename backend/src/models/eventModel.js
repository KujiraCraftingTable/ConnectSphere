const { query } = require('../config/db');

// Insert a new event record linked to a post
async function createEvent(postId, { title, location, startsAt, endsAt }) {
  const { rows } = await query(
    `INSERT INTO community_events (post_id, title, location, starts_at, ends_at)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING *`,
    [postId, title, location || null, startsAt, endsAt || null]
  );
  return rows[0];
}

// Fetch event data for a post, optionally including the requesting user's RSVP status
async function getEventByPostId(postId, requestingUserId = null) {
  const params = [postId];
  let userRsvpExpr = 'NULL::VARCHAR AS user_rsvp';
  if (requestingUserId) {
    params.push(requestingUserId);
    userRsvpExpr = `(SELECT er.status FROM event_rsvps er
                     WHERE er.event_id = e.id AND er.user_id = $${params.length}) AS user_rsvp`;
  }

  const { rows } = await query(
    `SELECT e.id, e.title, e.location, e.starts_at, e.ends_at, e.rsvp_count, ${userRsvpExpr}
     FROM community_events e
     WHERE e.post_id = $1`,
    params
  );
  return rows[0] || null;
}

// Fetch event by its own ID (used for RSVP validation); includes community_id from post
async function getEventById(eventId) {
  const { rows } = await query(
    `SELECT e.id, e.post_id, e.title, e.rsvp_count, p.community_id
     FROM community_events e
     JOIN posts p ON p.id = e.post_id
     WHERE e.id = $1`,
    [eventId]
  );
  return rows[0] || null;
}

// Upsert an RSVP; adjusts rsvp_count only for 'going' transitions
async function upsertRsvp(eventId, userId, status) {
  const { rows: existing } = await query(
    `SELECT status FROM event_rsvps WHERE event_id = $1 AND user_id = $2`,
    [eventId, userId]
  );

  await query(
    `INSERT INTO event_rsvps (event_id, user_id, status)
     VALUES ($1, $2, $3)
     ON CONFLICT (event_id, user_id)
     DO UPDATE SET status = $3, rsvp_at = NOW()`,
    [eventId, userId, status]
  );

  // Adjust rsvp_count based on going/not-going transitions
  const wasGoing = existing[0]?.status === 'going';
  const isGoing  = status === 'going';
  if (!wasGoing && isGoing) {
    await query(
      `UPDATE community_events SET rsvp_count = rsvp_count + 1 WHERE id = $1`,
      [eventId]
    );
  } else if (wasGoing && !isGoing) {
    await query(
      `UPDATE community_events SET rsvp_count = GREATEST(0, rsvp_count - 1) WHERE id = $1`,
      [eventId]
    );
  }
}

// Paginated list of users who RSVPed to an event
async function getEventRsvps(eventId, { limit = 20, offset = 0 } = {}) {
  const { rows } = await query(
    `SELECT u.id, u.username, u.display_name, u.avatar_color, er.status, er.rsvp_at
     FROM event_rsvps er
     JOIN users u ON u.id = er.user_id
     WHERE er.event_id = $1
     ORDER BY er.rsvp_at ASC
     LIMIT $2 OFFSET $3`,
    [eventId, limit, offset]
  );
  return rows;
}

module.exports = { createEvent, getEventByPostId, getEventById, upsertRsvp, getEventRsvps };
