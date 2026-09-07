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
      viewerId: req.userId,   // excludes blocked/blocking users from the results
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
    // If they've blocked us, we can't view their profile.
    // (The reverse direction is still viewable, so we can still tap "Unblock".)
    if (await userModel.hasBlocked(req.params.id, req.userId)) {
      const err = new Error('User not found');
      err.status = 404;
      return next(err);
    }

    // mode (hobby/work) → also return connection_count for that mode
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

// POST /api/users/:id/block — block a user (also removes any connection between the two)
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

// DELETE /api/users/:id/block — unblock
async function unblockUser(req, res, next) {
  try {
    await userModel.unblockUser(req.userId, req.params.id);
    res.json({ status: 'ok', blocked: false });
  } catch (err) {
    next(err);
  }
}

// GET /api/users/:id/blocked — whether we're blocking this user (+ either direction,
// used to hide/disable the chat input when we're blocked even though we're not the blocker)
async function blockStatus(req, res, next) {
  try {
    const [blocked, blockedEitherWay] = await Promise.all([
      userModel.hasBlocked(req.userId, req.params.id),
      userModel.isBlockedEitherWay(req.userId, req.params.id),
    ]);
    res.json({ blocked, blockedEitherWay });
  } catch (err) {
    next(err);
  }
}

// GET /api/users/blocked — list of users we're blocking
async function listBlocked(req, res, next) {
  try {
    const rows = await userModel.listBlocked(req.userId);
    res.json({ data: rows });
  } catch (err) {
    next(err);
  }
}

// PATCH /api/users/me — edit the JWT user's own profile (partial update)
async function updateMe(req, res, next) {
  try {
    const {
      display_name, bio, location, job_title, company,
      avatar_url, cover_url, dob, gender, dob_visibility,
      interests, skills, email,
    } = req.body;

    // Persona being edited: ?mode= or body.mode; not sent → the user's default_mode
    // (older clients that don't know about personas still edit the right identity).
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

    // Email is handled separately (not through the updateProfile whitelist): normalize + check unique.
    // Empty string = remove the email from the account.
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

    // Profile changed → rebuild the profile chunk (queue has retry, doesn't block the response)
    enqueueProfileEmbed(req.userId)
      .catch((err) => logger.warn({ err, userId: req.userId }, 'updateMe: enqueue profile embed failed'));

    // The owner's own response includes the real email + has_password + dob/dob_visibility/age
    // (findById is the public profile, so age there is already gated by dob_visibility,
    // and it doesn't include raw dob/email/has_password)
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

// POST /api/users/me/personas — create the persona for the second mode (first-time switch).
// Body: { mode, display_name*, bio?, job_title?/company?/skills? (work) | interests? (hobby) }
// Persona already exists → 409 (edit via PATCH /users/me?mode=...).
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

    // mode is already validated as 'hobby'/'work' → safe to interpolate into the column name
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

    // Mode-specific list: work = skills, hobby = interests (full replace)
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

    // New persona → rebuild the profile chunk for search/feed
    enqueueProfileEmbed(req.userId)
      .catch((err) => logger.warn({ err, userId: req.userId }, 'createPersona: enqueue embed failed'));

    const user = await userModel.findById(req.userId, mode);
    res.status(201).json({ data: user });
  } catch (err) {
    next(err);
  }
}

// DELETE /api/users/me — soft delete: confirm with password (Google accounts
// without a password type "DELETE" instead), then scrub PII + remove social links.
// Previously posted content is kept as-is, shown under the name "Deleted User".
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

/**
 * PATCH /users/me/default-mode — Body: { mode: 'hobby' | 'work' }
 *
 * Persists which mode the app opens in after login. Separate from `updateMe`,
 * whose own `mode` field means "which persona to edit," not "set my default" —
 * conflating the two would make `updateMe` ambiguous about which one a caller
 * meant. Before this endpoint existed, the client's mode switch only ever
 * mutated in-memory state and silently reverted on the next cold launch,
 * because default_mode was otherwise set once, only at registration.
 */
async function updateDefaultMode(req, res, next) {
  try {
    const { mode } = req.body;
    if (!['hobby', 'work'].includes(mode)) {
      return res.status(400).json({ error: 'mode must be hobby or work' });
    }

    await query(
      'UPDATE users SET default_mode = $1, updated_at = NOW() WHERE id = $2',
      [mode, req.userId]
    );
    res.json({ status: 'ok' });
  } catch (err) {
    next(err);
  }
}

module.exports = {
  listUsers, getUser, updateMe, createPersona, updateDefaultMode,
  blockUser, unblockUser, blockStatus, listBlocked, deleteMe,
};
