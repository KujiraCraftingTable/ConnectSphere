const { query } = require('../config/db');

// Bulk-insert poll options for a post in one parameterized query
async function createPollWithOptions(postId, options, endsAt = null) {
  const params = [postId, endsAt];
  const clauses = options.map((text, i) => {
    params.push(text);
    return `($1, $${params.length}, 0, ${i}, $2)`;
  });

  const { rows } = await query(
    `INSERT INTO poll_options (post_id, text, vote_count, position, ends_at)
     VALUES ${clauses.join(', ')}
     RETURNING *`,
    params
  );
  return rows;
}

// Fetch all options for a post and which option the requesting user has voted for
async function getPollWithVotes(postId, requestingUserId = null) {
  const { rows: options } = await query(
    `SELECT id, text, vote_count, position, ends_at
     FROM poll_options
     WHERE post_id = $1
     ORDER BY position`,
    [postId]
  );

  let userVote = null;
  if (requestingUserId) {
    const { rows } = await query(
      `SELECT pv.poll_option_id
       FROM poll_votes pv
       JOIN poll_options po ON po.id = pv.poll_option_id
       WHERE po.post_id = $1 AND pv.user_id = $2`,
      [postId, requestingUserId]
    );
    userVote = rows[0]?.poll_option_id || null;
  }

  return { options, userVote };
}

// Record a vote; throws 409 if user already voted on this poll (idempotent guard)
async function voteOnPoll(pollOptionId, userId) {
  // Check across all options of the same poll for an existing vote
  const { rows: existing } = await query(
    `SELECT pv.poll_option_id
     FROM poll_votes pv
     JOIN poll_options po ON po.id = pv.poll_option_id
     JOIN poll_options po2 ON po2.post_id = po.post_id AND po2.id = $1
     WHERE pv.user_id = $2`,
    [pollOptionId, userId]
  );
  if (existing.length > 0) {
    const err = new Error('You have already voted on this poll');
    err.status = 409;
    throw err;
  }

  await query(
    `INSERT INTO poll_votes (poll_option_id, user_id) VALUES ($1, $2)`,
    [pollOptionId, userId]
  );
  await query(
    `UPDATE poll_options SET vote_count = vote_count + 1 WHERE id = $1`,
    [pollOptionId]
  );
}

// Return the option ID the user voted for in the given post's poll, or null
async function getUserVote(postId, userId) {
  const { rows } = await query(
    `SELECT pv.poll_option_id
     FROM poll_votes pv
     JOIN poll_options po ON po.id = pv.poll_option_id
     WHERE po.post_id = $1 AND pv.user_id = $2`,
    [postId, userId]
  );
  return rows[0]?.poll_option_id || null;
}

module.exports = { createPollWithOptions, getPollWithVotes, voteOnPoll, getUserVote };
