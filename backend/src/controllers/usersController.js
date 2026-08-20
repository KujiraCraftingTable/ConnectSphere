const bcrypt = require('bcrypt');
const userModel = require('../models/userModel');
const { query } = require('../config/db');
const { enqueueProfileEmbed } = require('../queues/embedQueue');
const logger = require('../utils/logger');

// GET /api/users
async function listUsers(req, res, next) {
  try {
    const { mode, search, limit = '20', offset = '0' } = req.query;
    const filters = {
      mode, search,
      viewerId: req.userId,   // loại user đã chặn/bị chặn khỏi kết quả
      limit:  parseInt(limit, 10),
      offset: parseInt(offset, 10),
    };

    const [users, total] = await Promise.all([
      userModel.findAll(filters),
      userModel.countAll({ mode, search, viewerId: req.userId }),
    ]);

    res.json({
      data: users,
      pagination: { total, limit: filters.limit, offset: filters.offset },
    });
  } catch (err) {
    next(err);
  }
}

// GET /api/users/:id
async function getUser(req, res, next) {
  try {
    // Người đã chặn mình thì mình không xem được hồ sơ của họ.
    // (Chiều ngược lại vẫn xem được để còn bấm "Bỏ chặn".)
    if (await userModel.hasBlocked(req.params.id, req.userId)) {
      const err = new Error('User not found');
      err.status = 404;
      return next(err);
    }

    // mode (hobby/work) → trả kèm connection_count theo mode đó
    const mode = ['hobby', 'work'].includes(req.query.mode) ? req.query.mode : null;
    const user = await userModel.findById(req.params.id, mode);
    if (!user) {
      const err = new Error('User not found');
      err.status = 404;
      return next(err);
    }
    res.json({ data: user });
  } catch (err) {
    next(err);
  }
}

// POST /api/users/:id/block — chặn user (gỡ luôn mọi connection giữa 2 bên)
async function blockUser(req, res, next) {
  try {
    const targetId = req.params.id;
    if (targetId === req.userId) {
      return res.status(400).json({ error: 'Cannot block yourself' });
    }
    const target = await userModel.findById(targetId);
    if (!target) {
      const err = new Error('User not found');
      err.status = 404;
      return next(err);
    }

    await userModel.blockUser(req.userId, targetId);
    res.json({ status: 'ok', blocked: true });
  } catch (err) {
    next(err);
  }
}

// DELETE /api/users/:id/block — bỏ chặn
async function unblockUser(req, res, next) {
  try {
    await userModel.unblockUser(req.userId, req.params.id);
    res.json({ status: 'ok', blocked: false });
  } catch (err) {
    next(err);
  }
}

// GET /api/users/:id/blocked — mình có đang chặn user này không
async function blockStatus(req, res, next) {
  try {
    const blocked = await userModel.hasBlocked(req.userId, req.params.id);
    res.json({ blocked });
  } catch (err) {
    next(err);
  }
}

// GET /api/users/blocked — danh sách user mình đang chặn
async function listBlocked(req, res, next) {
  try {
    const rows = await userModel.listBlocked(req.userId);
    res.json({ data: rows });
  } catch (err) {
    next(err);
  }
}

// PATCH /api/users/me — sửa hồ sơ của chính user trong JWT (partial update)
async function updateMe(req, res, next) {
  try {
    const {
      display_name, bio, location, job_title, company,
      avatar_url, cover_url, dob, gender, dob_visibility,
      interests, skills, email,
    } = req.body;

    // Persona đang sửa: ?mode= hoặc body.mode; không gửi → default_mode của user
    // (client cũ chưa biết persona vẫn sửa đúng danh tính chính).
    let mode = req.query.mode || req.body.mode;
    if (!['hobby', 'work'].includes(mode)) {
      const { rows: [me] } = await query(
        'SELECT default_mode FROM users WHERE id = $1', [req.userId]
      );
      mode = me?.default_mode || 'hobby';
    }

    if (display_name !== undefined && !display_name?.trim()) {
      return res.status(400).json({ error: 'display_name cannot be empty' });
    }
    if (bio !== undefined && bio && bio.length > 500) {
      return res.status(400).json({ error: 'bio must be at most 500 characters' });
    }
    if (gender !== undefined && !['male', 'female', 'other'].includes(gender)) {
      return res.status(400).json({ error: 'Invalid gender' });
    }
    if (dob_visibility !== undefined && !['private', 'public'].includes(dob_visibility)) {
      return res.status(400).json({ error: 'dob_visibility must be private or public' });
    }

    // Email xử lý riêng (không qua whitelist updateProfile): normalize + check unique.
    // Chuỗi rỗng = gỡ email khỏi tài khoản.
    if (email !== undefined) {
      const normalized = email?.trim().toLowerCase() || null;
      if (normalized && !/^\S+@\S+\.\S+$/.test(normalized)) {
        return res.status(400).json({ error: 'Invalid email format' });
      }
      try {
        await query(
          'UPDATE users SET email = $1, updated_at = NOW() WHERE id = $2',
          [normalized, req.userId]
        );
      } catch (e) {
        if (e.code === '23505') return res.status(409).json({ error: 'Email already in use' });
        throw e;
      }
    }

    const fields = {};
    if (display_name !== undefined) fields.display_name = display_name.trim();
    if (bio !== undefined)          fields.bio          = bio?.trim() || null;
    if (location !== undefined)     fields.location     = location?.trim() || null;
    if (job_title !== undefined)    fields.job_title    = job_title?.trim() || null;
    if (company !== undefined)      fields.company      = company?.trim() || null;
    if (avatar_url !== undefined)   fields.avatar_url   = avatar_url || null;
    if (cover_url !== undefined)    fields.cover_url    = cover_url || null;
    if (dob !== undefined)          fields.dob          = dob || null;
    if (gender !== undefined)       fields.gender       = gender;
    if (dob_visibility !== undefined) fields.dob_visibility = dob_visibility;

    const user = await userModel.updateProfile(req.userId, fields, {
      interests: Array.isArray(interests) ? interests : null,
      skills:    Array.isArray(skills)    ? skills    : null,
      mode,
    });

    // Profile đổi → rebuild profile chunk (queue có retry, không block response)
    enqueueProfileEmbed(req.userId)
      .catch((err) => logger.warn({ err, userId: req.userId }, 'updateMe: enqueue profile embed failed'));

    // Response của chính chủ mang thêm email + has_password + dob/dob_visibility/age
    // thật (findById là profile công khai nên age đã bị gate theo dob_visibility,
    // và không chứa dob/email/has_password ở dạng thô)
    const { rows: [priv] } = await query(
      `SELECT email, dob, dob_visibility, age,
              (password_hash IS NOT NULL AND password_hash <> ''
               AND password_hash <> 'SEED_DATA') AS has_password
       FROM users WHERE id = $1`,
      [req.userId]
    );
    res.json({
      data: {
        ...user,
        email: priv.email,
        has_password: priv.has_password,
        dob: priv.dob,
        dob_visibility: priv.dob_visibility,
        age: priv.age,
      },
    });
  } catch (err) {
    next(err);
  }
}

// POST /api/users/me/personas — tạo persona cho mode thứ 2 (lần đầu switch).
// Body: { mode, display_name*, bio?, job_title?/company?/skills? (work) | interests? (hobby) }
// Persona đã tồn tại → 409 (sửa qua PATCH /users/me?mode=...).
async function createPersona(req, res, next) {
  try {
    const { mode, display_name, bio, job_title, company, skills, interests } = req.body;

    if (!['hobby', 'work'].includes(mode)) {
      return res.status(400).json({ error: 'mode must be hobby or work' });
    }
    if (!display_name?.trim()) {
      return res.status(400).json({ error: 'display_name is required' });
    }
    if (bio !== undefined && bio && bio.length > 500) {
      return res.status(400).json({ error: 'bio must be at most 500 characters' });
    }

    const { rows: [me] } = await query(
      `SELECT (hobby_display_name IS NOT NULL) AS hobby_setup,
              (work_display_name  IS NOT NULL) AS work_setup
       FROM users WHERE id = $1`,
      [req.userId]
    );
    if (!me) return res.status(404).json({ error: 'User not found' });
    if ((mode === 'hobby' && me.hobby_setup) || (mode === 'work' && me.work_setup)) {
      return res.status(409).json({ error: 'Persona already set up' });
    }

    // mode đã validate 'hobby'/'work' → an toàn để ghép tên cột
    const params = [req.userId, display_name.trim(), bio?.trim() || null];
    let extraSets = '';
    if (mode === 'work') {
      params.push(job_title?.trim() || null, company?.trim() || null);
      extraSets = ', job_title = $4, company = $5';
    }
    await query(
      `UPDATE users SET
         ${mode}_display_name = $2,
         ${mode}_bio          = $3
         ${extraSets},
         updated_at = NOW()
       WHERE id = $1`,
      params
    );

    // Danh sách riêng của mode: work = skills, hobby = interests (thay toàn bộ)
    const list  = mode === 'work' ? skills : interests;
    const table = mode === 'work' ? 'user_skills' : 'user_interests';
    const col   = mode === 'work' ? 'skill' : 'interest';
    if (Array.isArray(list)) {
      await query(`DELETE FROM ${table} WHERE user_id = $1`, [req.userId]);
      for (const item of list) {
        if (item?.trim()) {
          await query(
            `INSERT INTO ${table} (user_id, ${col}) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
            [req.userId, item.trim()]
          );
        }
      }
    }

    // Persona mới → rebuild profile chunk cho search/feed
    enqueueProfileEmbed(req.userId)
      .catch((err) => logger.warn({ err, userId: req.userId }, 'createPersona: enqueue embed failed'));

    const user = await userModel.findById(req.userId, mode);
    res.status(201).json({ data: user });
  } catch (err) {
    next(err);
  }
}

// DELETE /api/users/me — soft delete: xác nhận bằng mật khẩu (tài khoản Google
// chưa có mật khẩu thì gõ "DELETE"), sau đó scrub PII + gỡ liên kết xã hội.
// Nội dung đã đăng giữ nguyên, hiển thị dưới tên "Deleted User".
async function deleteMe(req, res, next) {
  try {
    const { password, confirmation } = req.body || {};

    const { rows: [user] } = await query(
      'SELECT password_hash, deleted_at FROM users WHERE id = $1', [req.userId]
    );
    if (!user || user.deleted_at) {
      return res.status(404).json({ error: 'User not found' });
    }

    const hasPassword = !!user.password_hash
      && user.password_hash !== '' && user.password_hash !== 'SEED_DATA';
    if (hasPassword) {
      if (typeof password !== 'string'
          || !(await bcrypt.compare(password, user.password_hash))) {
        return res.status(401).json({ error: 'Password is incorrect' });
      }
    } else if (confirmation !== 'DELETE') {
      return res.status(400).json({ error: 'Type DELETE to confirm' });
    }

    await userModel.softDeleteAccount(req.userId);
    logger.info({ userId: req.userId }, 'account soft-deleted');
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

module.exports = {
  listUsers, getUser, updateMe, createPersona,
  blockUser, unblockUser, blockStatus, listBlocked, deleteMe,
};
