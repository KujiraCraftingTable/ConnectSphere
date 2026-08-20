const { query } = require('../config/db');
const { personaCols, personaSetupClause, personaExpr } = require('../utils/personaSql');

// Base SELECT used by both findAll and findById.
// modeRef (vd '$2') → danh tính (display_name/bio/avatar_url/cover_url) resolve
// từ persona của mode đó; không có modeRef → cột gốc (bề mặt không gắn mode).
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

// Loại user đã chặn/bị chặn (2 chiều) khỏi kết quả, tính theo viewer
const notBlockedClause = (viewerRef, targetCol = 'u.id') => `
  NOT EXISTS (
    SELECT 1 FROM user_blocks ub
    WHERE (ub.blocker_id = ${viewerRef}::uuid AND ub.blocked_id = ${targetCol})
       OR (ub.blocker_id = ${targetCol} AND ub.blocked_id = ${viewerRef}::uuid)
  )
`;

// Loại user đã kết nối (accepted, 2 chiều) với viewer khỏi kết quả search —
// đã là bạn/đồng nghiệp thì không cần hiện lại để "kết nối" nữa.
// modeRef (nếu có) giới hạn theo mode connection tương ứng.
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

// Số bạn/kết nối chung giữa viewer và target trong mode — giao (INTERSECT) hai
// tập "đối tác accepted" của mỗi bên. modeRef (nếu có) giới hạn theo mode.
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
    // Chỉ hiện user đã setup persona của mode này — chưa setup = vô hình ở mode đó
    where += ` AND ${personaSetupClause(`$${modeIdx}`)}`;
  }
  // Ẩn người đã kết nối (accepted) với viewer trong mode hiện tại
  if (viewerIdx) {
    where += ` AND ${notConnectedClause(`$${viewerIdx}`, modeIdx ? `$${modeIdx}` : null)}`;
  }
  if (search) {
    params.push(`%${search}%`);
    const n = params.length;
    // Tìm trên danh tính persona của mode đang xem; field riêng của mode nào
    // chỉ match khi đang ở mode đó (interests = hobby, skills/job/company = work)
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
  // Bọc thành subquery để tính mutual_count trên đúng trang kết quả (sau LIMIT)
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
    // Chỉ đếm user đã setup persona của mode này (khớp filter của findAll)
    where += ` AND ${personaSetupClause(`$${modeIdx}`, 'users')}`;
  }
  // Ẩn người đã kết nối (accepted) với viewer trong mode hiện tại
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

// mode (nếu có) → danh tính theo persona của mode + connection_count trong mode đó
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
  // Bọc userSelect thành subquery để thêm cột connection_count vào SELECT ngoài
  const sql = `
    SELECT base.*, ${connCountSelect} AS connection_count
    FROM (${userSelect(modeRef)} WHERE u.id = $1 GROUP BY u.id) base
  `;
  const { rows } = await query(sql, params);
  return rows[0] || null;
}

// Cột được phép sửa qua PATCH /api/users/me — whitelist để không cho
// client sửa username/counter qua endpoint này (email sửa riêng ở controller
// vì cần normalize + check unique).
// 4 field danh tính thuộc persona → ghi vào cột của mode đang sửa.
const PERSONA_COLUMNS = ['display_name', 'bio', 'avatar_url', 'cover_url'];
const EDITABLE_COLUMNS = [
  'display_name', 'bio', 'location', 'job_title', 'company',
  'avatar_url', 'cover_url', 'dob', 'gender', 'dob_visibility',
];

// Update hồ sơ theo kiểu partial: chỉ ghi các field client gửi lên.
// mode: persona đang sửa — field danh tính ghi vào <mode>_*; nếu mode trùng
// default_mode thì đồng bộ luôn cột gốc (bề mặt không gắn mode như community
// vẫn hiển thị danh tính chính). interests/skills (nếu gửi) thay toàn bộ.
async function updateProfile(userId, fields, { interests = null, skills = null, mode = null } = {}) {
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

  // dob vừa đổi (kể cả xoá về NULL) → tính lại age ngay trong cùng câu UPDATE,
  // không đợi tới lần chạy ageJob kế tiếp (xem backend/src/jobs/ageJob.js)
  if (dobParamIdx !== null) {
    sets.push(`age = EXTRACT(YEAR FROM AGE($${dobParamIdx}::date))::int`);
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

  return findById(userId, mode);
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

// Soft delete tài khoản: gỡ mọi liên kết xã hội + scrub PII trên row users.
// Posts/comments/messages GIỮ NGUYÊN — JOIN users sẽ tự hiện "Deleted User".
// Chunks embedding bị xoá nên user + bài của họ biến khỏi search/feed gợi ý.
async function softDeleteAccount(userId) {
  // 1. Kết nối accepted: xoá + trừ follower/following của đối phương
  //    (một cặp có thể có 2 connection theo 2 mode → GROUP BY đếm đúng)
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
  // 2. Request pending còn lại
  await query(
    'DELETE FROM connections WHERE requester_id = $1 OR addressee_id = $1', [userId]
  );
  // 3. Rời mọi community + trừ member_count
  await query(
    `WITH gone AS (
       DELETE FROM community_members WHERE user_id = $1 RETURNING community_id
     )
     UPDATE communities SET member_count = GREATEST(member_count - 1, 0)
     WHERE id IN (SELECT community_id FROM gone)`,
    [userId]
  );
  // 4. Dọn dữ liệu cá nhân còn lại
  await query('DELETE FROM user_embedding_chunks WHERE user_id = $1', [userId]);
  await query('DELETE FROM user_interests  WHERE user_id = $1', [userId]);
  await query('DELETE FROM user_skills     WHERE user_id = $1', [userId]);
  await query('DELETE FROM stories         WHERE author_id = $1', [userId]);
  await query('DELETE FROM user_blocks     WHERE blocker_id = $1 OR blocked_id = $1', [userId]);
  await query('DELETE FROM password_resets WHERE user_id = $1', [userId]);
  await query('DELETE FROM user_notifications WHERE user_id = $1', [userId]);

  // 5. Scrub PII cuối cùng — username đổi để giải phóng tên cũ,
  //    password_hash/google_id/email NULL để không còn đường đăng nhập
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

// Danh sách user mình đang chặn (màn Blocked users trong Settings)
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
  blockUser, unblockUser, hasBlocked, isBlockedEitherWay, listBlocked,
  softDeleteAccount,
};
