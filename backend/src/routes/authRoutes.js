/**
 * authRoutes.js
 *
 * POST /api/auth/google   — verify Google ID token → return JWT
 * GET  /api/auth/me       — return current user from JWT
 * POST /api/auth/setup    — complete onboarding (username, displayName, dob, mode, interests, skills)
 * POST /api/auth/logout   — (stateless JWT — client just deletes token)
 */

const router = require('express').Router();
const jwt    = require('jsonwebtoken');
const { query } = require('../config/db');
const env    = require('../config/env');
const logger = require('../utils/logger');
const { enqueueProfileEmbed } = require('../queues/embedQueue');

// ── Helpers ───────────────────────────────────────────────────────────────────

function signToken(userId) {
  return jwt.sign({ sub: userId }, env.jwt.secret, { expiresIn: env.jwt.expiresIn });
}

async function getUserById(id) {
  const { rows } = await query(
    `SELECT u.*,
            COALESCE(
              json_agg(DISTINCT ui.interest) FILTER (WHERE ui.interest IS NOT NULL), '[]'
            ) AS interests,
            COALESCE(
              json_agg(DISTINCT us.skill)    FILTER (WHERE us.skill    IS NOT NULL), '[]'
            ) AS skills
     FROM users u
     LEFT JOIN user_interests ui ON ui.user_id = u.id
     LEFT JOIN user_skills    us ON us.user_id  = u.id
     WHERE u.id = $1
     GROUP BY u.id`,
    [id]
  );
  return rows[0] || null;
}

// ── Middleware: verify JWT ────────────────────────────────────────────────────

function authMiddleware(req, res, next) {
  const header = req.headers.authorization || '';
  const token  = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'No token' });

  try {
    const payload = jwt.verify(token, env.jwt.secret);
    req.userId = payload.sub;
    next();
  } catch {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}

// ── POST /api/auth/google ─────────────────────────────────────────────────────

router.post('/google', async (req, res, next) => {
  try {
    const { id_token } = req.body;
    if (!id_token) return res.status(400).json({ error: 'id_token is required' });

    // Verify với Google tokeninfo endpoint
    const googleRes = await fetch(
      `https://oauth2.googleapis.com/tokeninfo?id_token=${id_token}`,
      { signal: AbortSignal.timeout(10_000) }
    );

    if (!googleRes.ok) {
      return res.status(401).json({ error: 'Invalid Google token' });
    }

    const gData = await googleRes.json();

    // Kiểm tra aud (client ID) nếu đã config
    if (env.google.clientId && gData.aud !== env.google.clientId) {
      logger.warn({ aud: gData.aud }, 'Google token aud mismatch');
      // Trong dev: chỉ warn, không block
    }

    const googleId = gData.sub;
    const email    = gData.email;
    const name     = gData.name || email.split('@')[0];
    const picture  = gData.picture || null;

    if (!googleId || !email) {
      return res.status(401).json({ error: 'Missing Google user info' });
    }

    // Tìm user theo google_id
    let { rows: [user] } = await query(
      'SELECT id, is_setup FROM users WHERE google_id = $1',
      [googleId]
    );

    let isNewUser = false;

    if (!user) {
      // Thử tìm theo email (user đã có acc từ trước)
      const { rows: [existing] } = await query(
        'SELECT id, is_setup FROM users WHERE email = $1',
        [email]
      );

      if (existing) {
        // Link Google account vào user cũ
        await query('UPDATE users SET google_id = $1 WHERE id = $2', [googleId, existing.id]);
        user = existing;
      } else {
        // Tạo user mới (chưa setup)
        const username = `user_${googleId.slice(-8)}`;
        const { rows: [newUser] } = await query(
          `INSERT INTO users (google_id, email, display_name, username, password_hash, avatar_color, is_setup)
           VALUES ($1, $2, $3, $4, '', $5, FALSE)
           RETURNING id, is_setup`,
          [googleId, email, name, username, '#1877F2']
        );
        user = newUser;
        isNewUser = true;
      }
    }

    const token   = signToken(user.id);
    const profile = await getUserById(user.id);

    res.json({
      token,
      user:        profile,
      is_new_user: isNewUser || !user.is_setup,
    });
  } catch (err) { next(err); }
});

// ── GET /api/auth/me ──────────────────────────────────────────────────────────

router.get('/me', authMiddleware, async (req, res, next) => {
  try {
    const user = await getUserById(req.userId);
    if (!user) return res.status(404).json({ error: 'User not found' });
    res.json({ user });
  } catch (err) { next(err); }
});

// ── POST /api/auth/setup ──────────────────────────────────────────────────────

router.post('/setup', authMiddleware, async (req, res, next) => {
  try {
    const {
      username, display_name, dob,
      bio, location, default_mode,
      job_title, company, gender,
      interests = [], skills = [],
    } = req.body;

    if (!username?.trim())     return res.status(400).json({ error: 'username is required' });
    if (!display_name?.trim()) return res.status(400).json({ error: 'display_name is required' });
    if (!location?.trim())     return res.status(400).json({ error: 'location is required' });

    // Check username unique
    const { rows: [existing] } = await query(
      'SELECT id FROM users WHERE username = $1 AND id != $2',
      [username.trim(), req.userId]
    );
    if (existing) return res.status(409).json({ error: 'Username already taken' });

    // Update user profile
    await query(
      `UPDATE users SET
         username     = $1,
         display_name = $2,
         dob          = $3,
         bio          = $4,
         location     = $5,
         default_mode = $6,
         job_title    = $7,
         company      = $8,
         gender       = $9,
         is_setup     = TRUE,
         updated_at   = NOW()
       WHERE id = $10`,
      [
        username.trim(), display_name.trim(),
        dob || null, bio?.trim() || null,
        location.trim(),
        ['friend', 'colleague'].includes(default_mode) ? default_mode : 'friend',
        job_title?.trim() || null, company?.trim() || null,
        ['male', 'female', 'other'].includes(gender) ? gender : 'other',
        req.userId,
      ]
    );

    // Replace interests
    await query('DELETE FROM user_interests WHERE user_id = $1', [req.userId]);
    for (const interest of interests) {
      if (interest?.trim()) {
        await query(
          'INSERT INTO user_interests (user_id, interest) VALUES ($1, $2) ON CONFLICT DO NOTHING',
          [req.userId, interest.trim()]
        );
      }
    }

    // Replace skills
    await query('DELETE FROM user_skills WHERE user_id = $1', [req.userId]);
    for (const skill of skills) {
      if (skill?.trim()) {
        await query(
          'INSERT INTO user_skills (user_id, skill) VALUES ($1, $2) ON CONFLICT DO NOTHING',
          [req.userId, skill.trim()]
        );
      }
    }

    // Onboarding xong → build profile chunk lần đầu (queue có retry)
    enqueueProfileEmbed(req.userId)
      .catch((err) => logger.warn({ err, userId: req.userId }, 'setup: enqueue profile embed failed'));

    const user = await getUserById(req.userId);
    res.json({ user });
  } catch (err) { next(err); }
});

module.exports = { router, authMiddleware };
