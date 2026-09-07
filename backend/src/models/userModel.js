const { query, withTransaction } = require('../config/db');
const { personaCols, personaSetupClause, personaExpr } = require('../utils/personaSql');

// Base SELECT used by both findAll and findById.
// modeRef (e.g. '$2') → identity (display_name/bio/avatar_url/cover_url) resolves
// from that mode's persona; no modeRef → the legacy columns (mode-agnostic surfaces).
const userSelect = (modeRef = null) => `
  SELECT
    u.id, u.username,
    ${modeRef ? personaCols(modeRef) : 'u.display_name, u.bio, u.avatar_url, u.cover_url'},
    u.avatar_color,
    CASE WHEN u.dob_visibility = 'public' THEN u.age ELSE NULL END AS age,
    u.location, u.job_title, u.company, u.default_mode,
    (u.hobby_display_name IS NOT NULL) AS hobby_setup,
    (u.work_display_name  IS NOT NULL) AS work_setup,
    u.hobby_theme, u.work_theme,
    u.follower_count, u.following_count, u.post_count,
    u.created_at,
    COALESCE(json_agg(DISTINCT ui.interest) FILTER (WHERE ui.interest IS NOT NULL), '[]') AS interests,
    COALESCE(json_agg(DISTINCT us.skill)    FILTER (WHERE us.skill    IS NOT NULL), '[]') AS skills
  FROM users u
  LEFT JOIN user_interests ui ON ui.user_id = u.id
  LEFT JOIN user_skills    us ON us.user_id = u.id
`;

// Excludes users who are blocked/blocking (both directions) from results, relative to the viewer
const notBlockedClause = (viewerRef, targetCol = 'u.id') => `
  NOT EXISTS (
    SELECT 1 FROM user_blocks ub
    WHERE (ub.blocker_id = ${viewerRef}::uuid AND ub.blocked_id = ${targetCol})
       OR (ub.blocker_id = ${targetCol} AND ub.blocked_id = ${viewerRef}::uuid)
  )
`;

// Excludes users already connected (accepted, both directions) with the viewer from
// search results — no need to show someone again to "connect" once they already are.
// modeRef (if given) scopes this to the matching connection mode.
const notConnectedClause = (viewerRef, modeRef, targetCol = 'u.id') => `
  NOT EXISTS (
    SELECT 1 FROM connections c
    WHERE c.status = 'accepted'
      ${modeRef ? `AND c.mode = ${modeRef}` : ''}
      AND (
        (c.requester_id = ${viewerRef}::uuid AND c.addressee_id = ${targetCol})
        OR (c.requester_id = ${targetCol} AND c.addressee_id = ${viewerRef}::uuid)
      )
  )
`;

// Number of mutual friends/connections between viewer and target in the mode — the
// INTERSECT of each side's set of "accepted counterparts". modeRef (if given) scopes it to the mode.
const mutualCountSelect = (viewerRef, modeRef, targetCol) => `(
  SELECT COUNT(*)::int FROM (
    SELECT CASE WHEN c.requester_id = ${viewerRef}::uuid THEN c.addressee_id ELSE c.requester_id END
    FROM connections c
    WHERE c.status = 'accepted'
      ${modeRef ? `AND c.mode = ${modeRef}` : ''}
      AND (c.requester_id = ${viewerRef}::uuid OR c.addressee_id = ${viewerRef}::uuid)
    INTERSECT
    SELECT CASE WHEN c.requester_id = ${targetCol} THEN c.addressee_id ELSE c.requester_id END
    FROM connections c
    WHERE c.status = 'accepted'
      ${modeRef ? `AND c.mode = ${modeRef}` : ''}
      AND (c.requester_id = ${targetCol} OR c.addressee_id = ${targetCol})
  ) mutual
)`;

async function findAll({ mode, search, viewerId = null, limit = 20, offset = 0 }) {
  const params = [];
  let where = 'WHERE u.deleted_at IS NULL';
  let viewerIdx = null;
  let modeIdx = null;

  if (viewerId) {
    params.push(viewerId);
    viewerIdx = params.length;
    where += ` AND ${notBlockedClause(`$${viewerIdx}`)}`;
  }
  if (mode) {
    params.push(mode);
    modeIdx = params.length;
    // Only show users who've set up the persona for this mode — not set up = invisible in that mode
    where += ` AND ${personaSetupClause(`$${modeIdx}`)}`;
  }
  // Hide people already connected (accepted) with the viewer in the current mode
  if (viewerIdx) {
    where += ` AND ${notConnectedClause(`$${viewerIdx}`, modeIdx ? `$${modeIdx}` : null)}`;
  }
  if (search) {
    params.push(`%${search}%`);
    const n = params.length;
    // Search against the persona identity for the mode being viewed; mode-specific
    // fields only match while in that mode (interests = hobby, skills/job/company = work)
    const nameExpr = modeIdx ? personaExpr('display_name', `$${modeIdx}`) : 'u.display_name';
    const bioExpr  = modeIdx ? personaExpr('bio', `$${modeIdx}`)          : 'u.bio';
    const modeScoped = modeIdx
      ? `($${modeIdx} = 'work' AND (
           u.job_title ILIKE $${n} OR u.company ILIKE $${n} OR
           EXISTS (SELECT 1 FROM user_skills us WHERE us.user_id = u.id AND us.skill ILIKE $${n})
         )) OR
         ($${modeIdx} = 'hobby' AND
           EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = u.id AND ui.interest ILIKE $${n})
         )`
      : `u.job_title ILIKE $${n} OR u.company ILIKE $${n} OR
         EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = u.id AND ui.interest ILIKE $${n}) OR
         EXISTS (SELECT 1 FROM user_skills    us WHERE us.user_id = u.id AND us.skill    ILIKE $${n})`;
    where += ` AND (
      ${nameExpr} ILIKE $${n} OR
      u.username  ILIKE $${n} OR
      u.location  ILIKE $${n} OR
      ${bioExpr}  ILIKE $${n} OR
      ${modeScoped}
    )`;
  }

  params.push(limit, offset);
  // Wrapped in a subquery so mutual_count is computed on the correct result page (after LIMIT)
  const mutualSelect = viewerIdx
    ? mutualCountSelect(`$${viewerIdx}`, modeIdx ? `$${modeIdx}` : null, 'base.id')
    : '0';
  const sql = `
    SELECT base.*, ${mutualSelect} AS mutual_count
    FROM (
      ${userSelect(modeIdx ? `$${modeIdx}` : null)}
      ${where}
      GROUP BY u.id
      ORDER BY u.created_at DESC
      LIMIT $${params.length - 1} OFFSET $${params.length}
    ) base
    ORDER BY base.created_at DESC
  `;

  const { rows } = await query(sql, params);
  return rows;
}

async function countAll({ mode, search, viewerId = null }) {
  const params = [];
  let where = 'WHERE deleted_at IS NULL';
  let viewerIdx = null;
  let modeIdx = null;

  if (viewerId) {
    params.push(viewerId);
    viewerIdx = params.length;
    where += ` AND ${notBlockedClause(`$${viewerIdx}`, 'users.id')}`;
  }
  if (mode) {
    params.push(mode);
    modeIdx = params.length;
    // Only count users who've set up the persona for this mode (matches findAll's filter)
    where += ` AND ${personaSetupClause(`$${modeIdx}`, 'users')}`;
  }
  // Hide people already connected (accepted) with the viewer in the current mode
  if (viewerIdx) {
    where += ` AND ${notConnectedClause(`$${viewerIdx}`, modeIdx ? `$${modeIdx}` : null, 'users.id')}`;
  }
  if (search) {
    params.push(`%${search}%`);
    const n = params.length;
    const nameExpr = modeIdx ? personaExpr('display_name', `$${modeIdx}`, 'users') : 'display_name';
    const bioExpr  = modeIdx ? personaExpr('bio', `$${modeIdx}`, 'users')          : 'bio';
    const modeScoped = modeIdx
      ? `($${modeIdx} = 'work' AND (
           job_title ILIKE $${n} OR company ILIKE $${n} OR
           EXISTS (SELECT 1 FROM user_skills us WHERE us.user_id = users.id AND us.skill ILIKE $${n})
         )) OR
         ($${modeIdx} = 'hobby' AND
           EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = users.id AND ui.interest ILIKE $${n})
         )`
      : `job_title ILIKE $${n} OR company ILIKE $${n} OR
         EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = users.id AND ui.interest ILIKE $${n}) OR
         EXISTS (SELECT 1 FROM user_skills    us WHERE us.user_id = users.id AND us.skill    ILIKE $${n})`;
    where += ` AND (
      ${nameExpr} ILIKE $${n} OR username ILIKE $${n} OR location ILIKE $${n} OR ${bioExpr} ILIKE $${n} OR
      ${modeScoped}
    )`;
  }

  const { rows } = await query(`SELECT COUNT(*) FROM users ${where}`, params);
  return parseInt(rows[0].count, 10);
}

// mode (if given) → identity via that mode's persona + connection_count within that mode
async function findById(id, mode = null) {
  const params = [id];
  let connCountSelect = '0';
  let modeRef = null;
  if (mode) {
    params.push(mode);
    modeRef = `$${params.length}`;
    connCountSelect = `(
      SELECT COUNT(*)::int FROM connections c
      WHERE c.status = 'accepted' AND c.mode = ${modeRef}
        AND (c.requester_id = base.id OR c.addressee_id = base.id)
    )`;
  }
  // Wrap userSelect in a subquery so connection_count can be added to the outer SELECT
  const sql = `
    SELECT base.*, ${connCountSelect} AS connection_count
    FROM (${userSelect(modeRef)} WHERE u.id = $1 GROUP BY u.id) base
  `;
  const { rows } = await query(sql, params);
  return rows[0] || null;
}

// Columns allowed to be edited via PATCH /api/users/me — a whitelist so the
// client can't edit username/counters through this endpoint (email is handled
// separately in the controller since it needs normalize + uniqueness checks).
// The 4 persona identity fields are written to the column for the mode being edited.
const PERSONA_COLUMNS = ['display_name', 'bio', 'avatar_url', 'cover_url'];
const EDITABLE_COLUMNS = [
  'display_name', 'bio', 'location', 'job_title', 'company',
  'avatar_url', 'cover_url', 'dob', 'gender', 'dob_visibility',
];

// Partial profile update: only writes the fields the client sent.
// mode: the persona being edited — identity fields are written to <mode>_*; if
// mode matches default_mode, the legacy columns are synced too (mode-agnostic
// surfaces like community still show the primary identity). interests/skills
// (if sent) are fully replaced.
async function updateProfile(userId, fields, { interests = null, skills = null, mode = null } = {}) {
  // mode is spliced into a column identifier below (`${mode}_${col}`), so it
  // must be validated here rather than trusted from the caller — every other
  // site that does this same splice (usersController.js, authRoutes.js)
  // validates independently; this function should too, not rely solely on
  // updateMe (its one current caller) having already checked.
  if (mode && !['hobby', 'work'].includes(mode)) {
    throw new Error(`updateProfile: invalid mode "${mode}"`);
  }

  const sets   = [];
  const params = [userId];

  let syncLegacy = false;
  if (mode) {
    const { rows: [me] } = await query('SELECT default_mode FROM users WHERE id = $1', [userId]);
    syncLegacy = me?.default_mode === mode;
  }

  let dobParamIdx = null;
  for (const col of EDITABLE_COLUMNS) {
    if (fields[col] !== undefined) {
      params.push(fields[col]);
      if (mode && PERSONA_COLUMNS.includes(col)) {
        sets.push(`${mode}_${col} = $${params.length}`);
        if (syncLegacy) sets.push(`${col} = $${params.length}`);
      } else {
        sets.push(`${col} = $${params.length}`);
      }
      if (col === 'dob') dobParamIdx = params.length;
    }
  }

  // dob just changed (including being cleared to NULL) → recompute age right in the
  // same UPDATE statement, instead of waiting for the next ageJob run (see backend/src/jobs/ageJob.js)
  if (dobParamIdx !== null) {
    sets.push(`age = EXTRACT(YEAR FROM AGE($${dobParamIdx}::date))::int`);
  }

  // One transaction: the profile UPDATE plus the interests/skills replace must
  // be all-or-nothing — a failure after the DELETE previously wiped the lists.
  // The per-row INSERT loop is collapsed into a single UNNEST insert.
  await withTransaction(async (client) => {
    if (sets.length > 0) {
      await client.query(
        `UPDATE users SET ${sets.join(', ')}, updated_at = NOW() WHERE id = $1`,
        params
      );
    }

    if (Array.isArray(interests)) {
      const clean = [...new Set(interests.map((i) => i?.trim()).filter(Boolean))];
      await client.query('DELETE FROM user_interests WHERE user_id = $1', [userId]);
      if (clean.length) {
        await client.query(
          `INSERT INTO user_interests (user_id, interest)
           SELECT $1, unnest($2::text[]) ON CONFLICT DO NOTHING`,
          [userId, clean]
        );
      }
    }

    if (Array.isArray(skills)) {
      const clean = [...new Set(skills.map((s) => s?.trim()).filter(Boolean))];
      await client.query('DELETE FROM user_skills WHERE user_id = $1', [userId]);
      if (clean.length) {
        await client.query(
          `INSERT INTO user_skills (user_id, skill)
           SELECT $1, unnest($2::text[]) ON CONFLICT DO NOTHING`,
          [userId, clean]
        );
      }
    }
  });

  return findById(userId, mode);
}

// ── Block ─────────────────────────────────────────────────────────────────────

// Block a user: write to user_blocks + remove any connection between the two
// (removing an accepted connection also decrements follower/following on both sides).
async function blockUser(blockerId, blockedId) {
  await withTransaction(async (client) => {
    await client.query(
      `INSERT INTO user_blocks (blocker_id, blocked_id)
       VALUES ($1, $2) ON CONFLICT DO NOTHING`,
      [blockerId, blockedId]
    );

    const { rows: accepted } = await client.query(
      `DELETE FROM connections
       WHERE status = 'accepted'
         AND ((requester_id = $1 AND addressee_id = $2)
           OR (requester_id = $2 AND addressee_id = $1))
       RETURNING id`,
      [blockerId, blockedId]
    );
    if (accepted.length > 0) {
      await client.query(
        `UPDATE users
         SET follower_count  = GREATEST(follower_count  - $3, 0),
             following_count = GREATEST(following_count - $3, 0)
         WHERE id IN ($1, $2)`,
        [blockerId, blockedId, accepted.length]
      );
    }

    // Also remove any remaining pending/rejected requests
    await client.query(
      `DELETE FROM connections
       WHERE (requester_id = $1 AND addressee_id = $2)
          OR (requester_id = $2 AND addressee_id = $1)`,
      [blockerId, blockedId]
    );
  });
}

// Soft delete an account: remove all social links + scrub PII on the users row.
// Posts/comments/messages are KEPT AS-IS — the JOIN to users will naturally show "Deleted User".
// Embedding chunks are deleted so the user + their posts disappear from search/feed recommendations.
async function softDeleteAccount(userId) {
 // All ~13 writes below run in one transaction — a crash partway through
 // previously left a half-deleted account (social graph gone, but username /
 // email / password_hash still live and the account fully usable).
 await withTransaction(async (client) => {
  const query = client.query.bind(client);
  // 1. Accepted connections: delete + decrement follower/following on the other side
  //    (a pair could have 2 connections across 2 modes → GROUP BY counts them correctly)
  await query(
    `WITH gone AS (
       DELETE FROM connections
       WHERE status = 'accepted' AND (requester_id = $1 OR addressee_id = $1)
       RETURNING CASE WHEN requester_id = $1 THEN addressee_id ELSE requester_id END AS other_id
     )
     UPDATE users SET
       follower_count  = GREATEST(follower_count  - g.cnt, 0),
       following_count = GREATEST(following_count - g.cnt, 0)
     FROM (SELECT other_id, COUNT(*)::int AS cnt FROM gone GROUP BY other_id) g
     WHERE users.id = g.other_id`,
    [userId]
  );
  // 2. Any remaining pending requests
  await query(
    'DELETE FROM connections WHERE requester_id = $1 OR addressee_id = $1', [userId]
  );
  // 3. Hand off any community where this user is the sole admin — promote the
  //    most senior other member (moderators first, then earliest join) so the
  //    community isn't orphaned. Communities with no other members are left to
  //    empty out in the next step; nobody is locked out of anything.
  await query(
    `WITH sole_admin AS (
       SELECT cm.community_id
       FROM community_members cm
       WHERE cm.user_id = $1 AND cm.role = 'admin'
         AND NOT EXISTS (
           SELECT 1 FROM community_members o
           WHERE o.community_id = cm.community_id
             AND o.user_id <> $1 AND o.role = 'admin'
         )
     ),
     successor AS (
       SELECT DISTINCT ON (m.community_id) m.community_id, m.user_id
       FROM community_members m
       JOIN sole_admin s ON s.community_id = m.community_id
       WHERE m.user_id <> $1
       ORDER BY m.community_id,
                CASE m.role WHEN 'moderator' THEN 0 ELSE 1 END,
                m.joined_at ASC
     )
     UPDATE community_members cm
     SET role = 'admin'
     FROM successor su
     WHERE cm.community_id = su.community_id AND cm.user_id = su.user_id`,
    [userId]
  );
  // 4. Leave every community + decrement member_count
  await query(
    `WITH gone AS (
       DELETE FROM community_members WHERE user_id = $1 RETURNING community_id
     )
     UPDATE communities SET member_count = GREATEST(member_count - 1, 0)
     WHERE id IN (SELECT community_id FROM gone)`,
    [userId]
  );
  // 5. Clean up remaining personal data
  await query('DELETE FROM user_embedding_chunks WHERE user_id = $1', [userId]);
  await query('DELETE FROM user_interests  WHERE user_id = $1', [userId]);
  await query('DELETE FROM user_skills     WHERE user_id = $1', [userId]);
  await query('DELETE FROM stories         WHERE author_id = $1', [userId]);
  await query('DELETE FROM user_blocks     WHERE blocker_id = $1 OR blocked_id = $1', [userId]);
  await query('DELETE FROM password_resets WHERE user_id = $1', [userId]);
  await query('DELETE FROM user_notifications WHERE user_id = $1', [userId]);

  // 6. Final PII scrub — username changed to free up the old handle,
  //    password_hash/google_id/email set to NULL so there's no login path left
  await query(
    `UPDATE users SET
       username      = 'deleted_' || SUBSTRING(REPLACE(id::text, '-', ''), 1, 12),
       display_name  = 'Deleted User',
       password_hash = NULL,
       email         = NULL,
       google_id     = NULL,
       phone         = NULL,
       avatar_url    = NULL,
       bio           = NULL,
       hobby_display_name = NULL,
       hobby_bio          = NULL,
       hobby_avatar_url   = NULL,
       hobby_cover_url    = NULL,
       work_display_name  = NULL,
       work_bio           = NULL,
       work_avatar_url    = NULL,
       work_cover_url     = NULL,
       job_title     = NULL,
       company       = NULL,
       location      = NULL,
       ward_id       = NULL,
       dob           = NULL,
       avatar_color  = '#9E9E9E',
       deleted_at    = NOW(),
       updated_at    = NOW()
     WHERE id = $1`,
    [userId]
  );
 });
}

async function unblockUser(blockerId, blockedId) {
  await query(
    `DELETE FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2`,
    [blockerId, blockedId]
  );
}

// Have we blocked the target?
async function hasBlocked(blockerId, blockedId) {
  const { rows } = await query(
    `SELECT 1 FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2`,
    [blockerId, blockedId]
  );
  return rows.length > 0;
}

// List of users we're blocking (the Blocked users screen in Settings)
async function listBlocked(blockerId) {
  const { rows } = await query(
    `SELECT u.id, u.display_name, u.avatar_color, u.avatar_url,
            b.created_at AS blocked_at
     FROM user_blocks b
     JOIN users u ON u.id = b.blocked_id
     WHERE b.blocker_id = $1
     ORDER BY b.created_at DESC`,
    [blockerId]
  );
  return rows;
}

// Is there a block in either direction between the two users?
async function isBlockedEitherWay(userA, userB) {
  const { rows } = await query(
    `SELECT 1 FROM user_blocks
     WHERE (blocker_id = $1 AND blocked_id = $2)
        OR (blocker_id = $2 AND blocked_id = $1)`,
    [userA, userB]
  );
  return rows.length > 0;
}

module.exports = {
  findAll, countAll, findById, updateProfile,
  blockUser, unblockUser, hasBlocked, isBlockedEitherWay, listBlocked,
  softDeleteAccount,
};
