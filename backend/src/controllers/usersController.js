const userModel = require('../models/userModel');
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

    const user = await userModel.findById(req.params.id);
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

// PATCH /api/users/me — sửa hồ sơ của chính user trong JWT (partial update)
async function updateMe(req, res, next) {
  try {
    const {
      display_name, bio, location, job_title, company,
      avatar_url, dob, gender, interests, skills,
    } = req.body;

    if (display_name !== undefined && !display_name?.trim()) {
      return res.status(400).json({ error: 'display_name cannot be empty' });
    }
    if (bio !== undefined && bio && bio.length > 500) {
      return res.status(400).json({ error: 'bio must be at most 500 characters' });
    }
    if (gender !== undefined && !['male', 'female', 'other'].includes(gender)) {
      return res.status(400).json({ error: 'Invalid gender' });
    }

    const fields = {};
    if (display_name !== undefined) fields.display_name = display_name.trim();
    if (bio !== undefined)          fields.bio          = bio?.trim() || null;
    if (location !== undefined)     fields.location     = location?.trim() || null;
    if (job_title !== undefined)    fields.job_title    = job_title?.trim() || null;
    if (company !== undefined)      fields.company      = company?.trim() || null;
    if (avatar_url !== undefined)   fields.avatar_url   = avatar_url || null;
    if (dob !== undefined)          fields.dob          = dob || null;
    if (gender !== undefined)       fields.gender       = gender;

    const user = await userModel.updateProfile(req.userId, fields, {
      interests: Array.isArray(interests) ? interests : null,
      skills:    Array.isArray(skills)    ? skills    : null,
    });

    // Profile đổi → rebuild profile chunk (queue có retry, không block response)
    enqueueProfileEmbed(req.userId)
      .catch((err) => logger.warn({ err, userId: req.userId }, 'updateMe: enqueue profile embed failed'));

    res.json({ data: user });
  } catch (err) {
    next(err);
  }
}

module.exports = { listUsers, getUser, updateMe, blockUser, unblockUser, blockStatus };
