const { query } = require('../config/db');

// Base SELECT used by both findAll and findById
const USER_SELECT = `
  SELECT
    u.id, u.username, u.display_name, u.bio, u.avatar_color, u.avatar_url,
    u.location, u.job_title, u.company, u.default_mode,
    u.friend_theme, u.colleague_theme,
    u.follower_count, u.following_count, u.post_count,
    u.created_at,
    COALESCE(json_agg(DISTINCT ui.interest) FILTER (WHERE ui.interest IS NOT NULL), '[]') AS interests,
    COALESCE(json_agg(DISTINCT us.skill)    FILTER (WHERE us.skill    IS NOT NULL), '[]') AS skills
  FROM users u
  LEFT JOIN user_interests ui ON ui.user_id = u.id
  LEFT JOIN user_skills    us ON us.user_id = u.id
`;

// Loại user đã chặn/bị chặn (2 chiều) khỏi kết quả, tính theo viewer
const notBlockedClause = (viewerRef, targetCol = 'u.id') => `
  NOT EXISTS (
    SELECT 1 FROM user_blocks ub
    WHERE (ub.blocker_id = ${viewerRef}::uuid AND ub.blocked_id = ${targetCol})
       OR (ub.blocker_id = ${targetCol} AND ub.blocked_id = ${viewerRef}::uuid)
  )
`;

async function findAll({ mode, search, viewerId = null, limit = 20, offset = 0 }) {
  const params = [];
  let where = 'WHERE 1=1';

  if (viewerId) {
    params.push(viewerId);
    where += ` AND ${notBlockedClause(`$${params.length}`)}`;
  }
  if (mode) {
    params.push(mode);
    where += ` AND u.default_mode = $${params.length}`;
  }
  if (search) {
    params.push(`%${search}%`);
    const n = params.length;
    where += ` AND (
      u.display_name ILIKE $${n} OR
      u.username     ILIKE $${n} OR
      u.job_title    ILIKE $${n} OR
      u.company      ILIKE $${n} OR
      u.location     ILIKE $${n} OR
      u.bio          ILIKE $${n} OR
      EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = u.id AND ui.interest ILIKE $${n}) OR
      EXISTS (SELECT 1 FROM user_skills    us WHERE us.user_id = u.id AND us.skill    ILIKE $${n})
    )`;
  }

  params.push(limit, offset);
  const sql = `
    ${USER_SELECT}
    ${where}
    GROUP BY u.id
    ORDER BY u.created_at DESC
    LIMIT $${params.length - 1} OFFSET $${params.length}
  `;

  const { rows } = await query(sql, params);
  return rows;
}

async function countAll({ mode, search, viewerId = null }) {
  const params = [];
  let where = 'WHERE 1=1';

  if (viewerId) {
    params.push(viewerId);
    where += ` AND ${notBlockedClause(`$${params.length}`, 'users.id')}`;
  }
  if (mode) {
    params.push(mode);
    where += ` AND default_mode = $${params.length}`;
  }
  if (search) {
    params.push(`%${search}%`);
    const n = params.length;
    where += ` AND (
      display_name ILIKE $${n} OR username ILIKE $${n} OR
      job_title ILIKE $${n} OR company ILIKE $${n} OR location ILIKE $${n} OR bio ILIKE $${n} OR
      EXISTS (SELECT 1 FROM user_interests ui WHERE ui.user_id = users.id AND ui.interest ILIKE $${n}) OR
      EXISTS (SELECT 1 FROM user_skills    us WHERE us.user_id = users.id AND us.skill    ILIKE $${n})
    )`;
  }

  const { rows } = await query(`SELECT COUNT(*) FROM users ${where}`, params);
  return parseInt(rows[0].count, 10);
}

async function findById(id) {
  const sql = `${USER_SELECT} WHERE u.id = $1 GROUP BY u.id`;
  const { rows } = await query(sql, [id]);
  return rows[0] || null;
}

// Cột được phép sửa qua PATCH /api/users/me — whitelist để không cho
// client sửa username/email/counter qua endpoint này.
const EDITABLE_COLUMNS = [
  'display_name', 'bio', 'location', 'job_title', 'company',
  'avatar_url', 'dob', 'gender',
];

// Update hồ sơ theo kiểu partial: chỉ ghi các field client gửi lên.
// interests/skills (nếu gửi) thay thế toàn bộ danh sách cũ.
async function updateProfile(userId, fields, { interests = null, skills = null } = {}) {
  const sets   = [];
  const params = [userId];

  for (const col of EDITABLE_COLUMNS) {
    if (fields[col] !== undefined) {
      params.push(fields[col]);
      sets.push(`${col} = $${params.length}`);
    }
  }

  if (sets.length > 0) {
    await query(
      `UPDATE users SET ${sets.join(', ')}, updated_at = NOW() WHERE id = $1`,
      params
    );
  }

  if (Array.isArray(interests)) {
    await query('DELETE FROM user_interests WHERE user_id = $1', [userId]);
    for (const interest of interests) {
      if (interest?.trim()) {
        await query(
          'INSERT INTO user_interests (user_id, interest) VALUES ($1, $2) ON CONFLICT DO NOTHING',
          [userId, interest.trim()]
        );
      }
    }
  }

  if (Array.isArray(skills)) {
    await query('DELETE FROM user_skills WHERE user_id = $1', [userId]);
    for (const skill of skills) {
      if (skill?.trim()) {
        await query(
          'INSERT INTO user_skills (user_id, skill) VALUES ($1, $2) ON CONFLICT DO NOTHING',
          [userId, skill.trim()]
        );
      }
    }
  }

  return findById(userId);
}

// ── Block ─────────────────────────────────────────────────────────────────────

// Chặn user: ghi user_blocks + gỡ mọi connection giữa 2 người
// (connection accepted bị gỡ thì trừ lại follower/following cả 2 phía).
async function blockUser(blockerId, blockedId) {
  await query(
    `INSERT INTO user_blocks (blocker_id, blocked_id)
     VALUES ($1, $2) ON CONFLICT DO NOTHING`,
    [blockerId, blockedId]
  );

  const { rows: accepted } = await query(
    `DELETE FROM connections
     WHERE status = 'accepted'
       AND ((requester_id = $1 AND addressee_id = $2)
         OR (requester_id = $2 AND addressee_id = $1))
     RETURNING id`,
    [blockerId, blockedId]
  );
  if (accepted.length > 0) {
    await query(
      `UPDATE users
       SET follower_count  = GREATEST(follower_count  - $3, 0),
           following_count = GREATEST(following_count - $3, 0)
       WHERE id IN ($1, $2)`,
      [blockerId, blockedId, accepted.length]
    );
  }

  // Gỡ nốt các request pending/rejected còn lại
  await query(
    `DELETE FROM connections
     WHERE (requester_id = $1 AND addressee_id = $2)
        OR (requester_id = $2 AND addressee_id = $1)`,
    [blockerId, blockedId]
  );
}

async function unblockUser(blockerId, blockedId) {
  await query(
    `DELETE FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2`,
    [blockerId, blockedId]
  );
}

// Mình đã chặn target chưa?
async function hasBlocked(blockerId, blockedId) {
  const { rows } = await query(
    `SELECT 1 FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2`,
    [blockerId, blockedId]
  );
  return rows.length > 0;
}

// Có block theo chiều bất kỳ giữa 2 user không?
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
  blockUser, unblockUser, hasBlocked, isBlockedEitherWay,
};
