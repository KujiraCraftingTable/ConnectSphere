/**
 * authRoutes.js
 *
 * POST /api/auth/register        — create account with username + password → return JWT
 * POST /api/auth/login           — verify username + password → return JWT
 * POST /api/auth/google          — verify Google ID token → return JWT
 * GET  /api/auth/me               — return current user from JWT
 * GET  /api/auth/check-username   — realtime check while typing a username during onboarding (?username=...)
 * POST /api/auth/setup            — complete onboarding (username, displayName, dob, mode, interests, skills)
 * POST /api/auth/change-password  — change password (Google-only account: set for the first time, no current password needed)
 * POST /api/auth/forgot-password  — issue a 6-digit OTP via email (dev: logged to console)
 * POST /api/auth/reset-password   — reset password using the OTP
 * POST /api/auth/logout           — (stateless JWT — client just deletes token)
 */

const router    = require('express').Router();
const jwt       = require('jsonwebtoken');
const bcrypt    = require('bcrypt');
const crypto    = require('crypto');
const rateLimit = require('express-rate-limit');
const { query } = require('../config/db');
const env    = require('../config/env');
const logger = require('../utils/logger');
const { personaExpr } = require('../utils/personaSql');
const { enqueueProfileEmbed } = require('../queues/embedQueue');
const { sendPasswordResetOTP } = require('../services/mailerService');

const BCRYPT_ROUNDS   = 12;
const USERNAME_REGEX  = /^[a-z0-9_]{3,30}$/;  // matches the filter on the iOS onboarding side
const MIN_PASSWORD_LEN = 8;

// Tighter than the global limiter (1000/15m): guards against password brute-forcing
const passwordAuthLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many attempts, please try again later' },
});

// ── Helpers ───────────────────────────────────────────────────────────────────

function signToken(userId) {
  return jwt.sign({ sub: userId }, env.jwt.secret, { expiresIn: env.jwt.expiresIn });
}

async function getUserById(id) {
  // Top-level identity (display_name/bio/avatar/cover) resolves from the
  // default_mode persona — the mode the app will open in after login. Also
  // includes a setup flag for both personas so the client knows when it
  // needs to block a mode switch behind the persona-creation form.
  const { rows } = await query(
    `SELECT u.*,
            ${personaExpr('display_name', 'u.default_mode')} AS display_name,
            ${personaExpr('bio', 'u.default_mode')}          AS bio,
            ${personaExpr('avatar_url', 'u.default_mode')}   AS avatar_url,
            ${personaExpr('cover_url', 'u.default_mode')}    AS cover_url,
            (u.hobby_display_name IS NOT NULL) AS hobby_setup,
            (u.work_display_name  IS NOT NULL) AS work_setup,
            (u.password_hash IS NOT NULL AND u.password_hash <> ''
             AND u.password_hash <> 'SEED_DATA')                    AS has_password,
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
  const user = rows[0] || null;
  if (user) {
    // Never return the password hash / google id to the client
    delete user.password_hash;
    delete user.google_id;
  }
  return user;
}

// ── Middleware: verify JWT ────────────────────────────────────────────────────

async function authMiddleware(req, res, next) {
  const header = req.headers.authorization || '';
  const token  = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'No token' });

  let payload;
  try {
    payload = jwt.verify(token, env.jwt.secret);
  } catch {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }

  try {
    // A soft-deleted account's token becomes invalid immediately, even if it
    // hasn't expired yet. Uses the same error message as an invalid token so
    // the account's status isn't leaked.
    const { rows: [u] } = await query(
      'SELECT deleted_at FROM users WHERE id = $1', [payload.sub]
    );
    if (!u || u.deleted_at) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }
    req.userId = payload.sub;
    next();
  } catch (err) {
    next(err);
  }
}

// ── POST /api/auth/register ───────────────────────────────────────────────────
// Creates a minimal account (username + password); the rest of the profile
// is handled by onboarding (POST /auth/setup) — exactly like a new Google user.

router.post('/register', passwordAuthLimiter, async (req, res, next) => {
  try {
    const username = req.body.username?.trim().toLowerCase();
    const password = req.body.password;

    if (!username || !USERNAME_REGEX.test(username)) {
      return res.status(400).json({ error: 'Username must be 3-30 characters: lowercase letters, numbers, underscore' });
    }
    if (typeof password !== 'string' || password.length < MIN_PASSWORD_LEN) {
      return res.status(400).json({ error: `Password must be at least ${MIN_PASSWORD_LEN} characters` });
    }

    const { rows: [existing] } = await query(
      'SELECT id FROM users WHERE username = $1', [username]
    );
    if (existing) return res.status(409).json({ error: 'Username already taken' });

    const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);
    // Temporary display_name = username (NOT NULL) — the user changes it during onboarding
    const { rows: [user] } = await query(
      `INSERT INTO users (username, password_hash, display_name, is_setup)
       VALUES ($1, $2, $1, FALSE)
       RETURNING id`,
      [username, passwordHash]
    );

    const token   = signToken(user.id);
    const profile = await getUserById(user.id);
    logger.info({ userId: user.id }, 'auth: new password account registered');

    res.status(201).json({ token, user: profile, is_new_user: true });
  } catch (err) { next(err); }
});

// ── POST /api/auth/login ──────────────────────────────────────────────────────

router.post('/login', passwordAuthLimiter, async (req, res, next) => {
  try {
    const username = req.body.username?.trim().toLowerCase();
    const password = req.body.password;

    if (!username || typeof password !== 'string' || !password) {
      return res.status(400).json({ error: 'username and password are required' });
    }

    const { rows: [user] } = await query(
      'SELECT id, password_hash, is_setup FROM users WHERE username = $1', [username]
    );

    // A Google account (empty/NULL password_hash) can't log in with a password.
    // Returns the same message as a wrong password so we don't leak which usernames exist.
    if (!user || !user.password_hash || user.password_hash === 'SEED_DATA') {
      return res.status(401).json({ error: 'Invalid username or password' });
    }

    const ok = await bcrypt.compare(password, user.password_hash);
    if (!ok) return res.status(401).json({ error: 'Invalid username or password' });

    const token   = signToken(user.id);
    const profile = await getUserById(user.id);

    // Registered but exited before onboarding → logging back in still lands in onboarding
    res.json({ token, user: profile, is_new_user: !user.is_setup });
  } catch (err) { next(err); }
});

// ── POST /api/auth/google ─────────────────────────────────────────────────────

router.post('/google', async (req, res, next) => {
  try {
    const { id_token } = req.body;
    if (!id_token) return res.status(400).json({ error: 'id_token is required' });

    // Verify against Google's tokeninfo endpoint
    const googleRes = await fetch(
      `https://oauth2.googleapis.com/tokeninfo?id_token=${id_token}`,
      { signal: AbortSignal.timeout(10_000) }
    );

    if (!googleRes.ok) {
      return res.status(401).json({ error: 'Invalid Google token' });
    }

    const gData = await googleRes.json();

    // Enforce the token audience. Without this, an ID token minted for ANY
    // Google OAuth client is accepted and linked to the matching email →
    // account takeover. Require GOOGLE_CLIENT_ID to be configured (except in a
    // local dev run, where we warn loudly instead of hard-failing).
    if (env.google.clientId) {
      if (gData.aud !== env.google.clientId) {
        logger.warn({ aud: gData.aud }, 'Google token aud mismatch — rejected');
        return res.status(401).json({ error: 'Invalid Google token' });
      }
    } else if (env.NODE_ENV === 'production') {
      logger.error('GOOGLE_CLIENT_ID is not set — refusing Google sign-in in production');
      return res.status(503).json({ error: 'Google sign-in is not configured' });
    } else {
      logger.warn('GOOGLE_CLIENT_ID not set — skipping aud check (dev only)');
    }

    // Reject unverified emails: an attacker could otherwise attach an
    // unverified Google identity carrying someone else's address.
    if (gData.email_verified === 'false' || gData.email_verified === false) {
      return res.status(401).json({ error: 'Google email is not verified' });
    }

    const googleId = gData.sub;
    const email    = gData.email;
    const name     = gData.name || (email ? email.split('@')[0] : null);
    const picture  = gData.picture || null;

    if (!googleId || !email) {
      return res.status(401).json({ error: 'Missing Google user info' });
    }

    // Look up the user by google_id
    let { rows: [user] } = await query(
      'SELECT id, is_setup FROM users WHERE google_id = $1',
      [googleId]
    );

    let isNewUser = false;

    if (!user) {
      // Try looking up by email (user already had an account before)
      const { rows: [existing] } = await query(
        'SELECT id, is_setup FROM users WHERE email = $1',
        [email]
      );

      if (existing) {
        // Link the Google account to the existing user
        await query('UPDATE users SET google_id = $1 WHERE id = $2', [googleId, existing.id]);
        user = existing;
      } else {
        // Create a new user (not yet set up)
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

// ── GET /api/auth/check-username ──────────────────────────────────────────────
// Realtime availability check called while typing a username during onboarding.
// Returns { available: boolean } — excludes the current user themself (so keeping your old username still counts as valid).

router.get('/check-username', authMiddleware, async (req, res, next) => {
  try {
    const username = (req.query.username || '').trim().toLowerCase();
    if (!username) return res.status(400).json({ error: 'username is required' });

    const { rows: [existing] } = await query(
      'SELECT id FROM users WHERE username = $1 AND id != $2',
      [username, req.userId]
    );
    res.json({ available: !existing });
  } catch (err) { next(err); }
});

// ── POST /api/auth/setup ──────────────────────────────────────────────────────

router.post('/setup', authMiddleware, async (req, res, next) => {
  try {
    const {
      username, display_name, dob, dob_visibility,
      bio, location, default_mode,
      job_title, company, gender,
      interests = [], skills = [],
    } = req.body;

    if (!username?.trim())     return res.status(400).json({ error: 'username is required' });
    if (!display_name?.trim()) return res.status(400).json({ error: 'display_name is required' });
    if (!location?.trim())     return res.status(400).json({ error: 'location is required' });

    // Birthday is required (it unlocks the age-range filter for AI search) —
    // there's no minimum age limit, it just needs to exist and be a valid past date.
    if (!dob?.trim()) return res.status(400).json({ error: 'dob is required' });
    const dobDate = new Date(dob);
    if (Number.isNaN(dobDate.getTime()) || dobDate.getTime() >= Date.now()) {
      return res.status(400).json({ error: 'dob must be a valid past date' });
    }

    // dob_visibility: defaults to private (safe default) if the client doesn't send it
    const dobVisibility = dob_visibility === undefined ? 'private' : dob_visibility;
    if (!['private', 'public'].includes(dobVisibility)) {
      return res.status(400).json({ error: 'dob_visibility must be private or public' });
    }

    // Check username unique
    const { rows: [existing] } = await query(
      'SELECT id FROM users WHERE username = $1 AND id != $2',
      [username.trim(), req.userId]
    );
    if (existing) return res.status(409).json({ error: 'Username already taken' });

    // Update user profile — the onboarding identity is written to the persona
    // of the chosen mode (the other mode's persona is left empty; the first
    // switch to it will prompt a separate creation form); the base
    // display_name/bio columns keep a copy as a fallback for mode-agnostic surfaces.
    const mode = ['hobby', 'work'].includes(default_mode) ? default_mode : 'hobby';
    await query(
      `UPDATE users SET
         username     = $1,
         display_name = $2,
         ${mode}_display_name = $2,
         dob          = $3,
         age          = EXTRACT(YEAR FROM AGE($3::date))::int,
         bio          = $4,
         ${mode}_bio  = $4,
         location     = $5,
         default_mode = $6,
         job_title    = $7,
         company      = $8,
         gender       = $9,
         dob_visibility = $10,
         is_setup     = TRUE,
         updated_at   = NOW()
       WHERE id = $11`,
      [
        username.trim(), display_name.trim(),
        dob.trim(), bio?.trim() || null,
        location.trim(),
        mode,
        job_title?.trim() || null, company?.trim() || null,
        ['male', 'female', 'other'].includes(gender) ? gender : 'other',
        dobVisibility,
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

    // Onboarding done → build the profile chunk for the first time (queue retries on failure)
    enqueueProfileEmbed(req.userId)
      .catch((err) => logger.warn({ err, userId: req.userId }, 'setup: enqueue profile embed failed'));

    const user = await getUserById(req.userId);
    res.json({ user });
  } catch (err) { next(err); }
});

// ── POST /api/auth/change-password ────────────────────────────────────────────
// Changes the password while logged in. A pure Google account (no password yet)
// gets its password set for the first time without needing current_password.

router.post('/change-password', authMiddleware, passwordAuthLimiter, async (req, res, next) => {
  try {
    const { current_password, new_password } = req.body;
    if (typeof new_password !== 'string' || new_password.length < MIN_PASSWORD_LEN) {
      return res.status(400).json({ error: `Password must be at least ${MIN_PASSWORD_LEN} characters` });
    }

    const { rows: [user] } = await query(
      'SELECT password_hash FROM users WHERE id = $1', [req.userId]
    );
    if (!user) return res.status(404).json({ error: 'User not found' });

    const hasPassword = !!user.password_hash
      && user.password_hash !== '' && user.password_hash !== 'SEED_DATA';
    if (hasPassword) {
      if (typeof current_password !== 'string'
          || !(await bcrypt.compare(current_password, user.password_hash))) {
        return res.status(401).json({ error: 'Current password is incorrect' });
      }
    }

    const hash = await bcrypt.hash(new_password, BCRYPT_ROUNDS);
    await query(
      'UPDATE users SET password_hash = $1, updated_at = NOW() WHERE id = $2',
      [hash, req.userId]
    );
    logger.info({ userId: req.userId }, 'auth: password changed');
    res.json({ status: 'ok', has_password: true });
  } catch (err) { next(err); }
});

// ── POST /api/auth/forgot-password ────────────────────────────────────────────
// Accepts either a username or an email. ALWAYS returns a generic response
// so we never leak which account exists / has an email. The 6-digit OTP is
// bcrypt-hashed and expires in 10 minutes; issuing a new code invalidates any
// previous unused code.

const OTP_TTL_MINUTES = 10;

router.post('/forgot-password', passwordAuthLimiter, async (req, res, next) => {
  try {
    const identifier = req.body.identifier?.trim().toLowerCase();
    if (!identifier) return res.status(400).json({ error: 'identifier is required' });

    const generic = {
      status: 'ok',
      message: 'If the account has an email on file, a code has been sent',
    };

    const { rows: [user] } = await query(
      'SELECT id, email FROM users WHERE username = $1 OR email = $1', [identifier]
    );
    if (!user || !user.email) return res.json(generic);

    const otp     = crypto.randomInt(0, 1_000_000).toString().padStart(6, '0');
    const otpHash = await bcrypt.hash(otp, BCRYPT_ROUNDS);

    await query(
      'UPDATE password_resets SET used_at = NOW() WHERE user_id = $1 AND used_at IS NULL',
      [user.id]
    );
    await query(
      `INSERT INTO password_resets (user_id, otp_hash, expires_at)
       VALUES ($1, $2, NOW() + INTERVAL '${OTP_TTL_MINUTES} minutes')`,
      [user.id, otpHash]
    );

    await sendPasswordResetOTP(user.email, otp);
    res.json(generic);
  } catch (err) { next(err); }
});

// ── POST /api/auth/reset-password ─────────────────────────────────────────────
// Resets the password using the OTP. Every failure branch (user doesn't exist /
// wrong code / expired code) returns the same message so no information is leaked.

router.post('/reset-password', passwordAuthLimiter, async (req, res, next) => {
  try {
    const identifier  = req.body.identifier?.trim().toLowerCase();
    const otp         = req.body.otp?.trim();
    const newPassword = req.body.new_password;

    if (!identifier || !otp) {
      return res.status(400).json({ error: 'identifier and otp are required' });
    }
    if (typeof newPassword !== 'string' || newPassword.length < MIN_PASSWORD_LEN) {
      return res.status(400).json({ error: `Password must be at least ${MIN_PASSWORD_LEN} characters` });
    }

    const invalid = () => res.status(401).json({ error: 'Invalid or expired code' });

    const { rows: [user] } = await query(
      'SELECT id FROM users WHERE username = $1 OR email = $1', [identifier]
    );
    if (!user) return invalid();

    const { rows: [reset] } = await query(
      `SELECT id, otp_hash FROM password_resets
       WHERE user_id = $1 AND used_at IS NULL AND expires_at > NOW()
       ORDER BY created_at DESC LIMIT 1`,
      [user.id]
    );
    if (!reset || !(await bcrypt.compare(otp, reset.otp_hash))) return invalid();

    const hash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);
    await query(
      'UPDATE users SET password_hash = $1, updated_at = NOW() WHERE id = $2',
      [hash, user.id]
    );
    await query('UPDATE password_resets SET used_at = NOW() WHERE id = $1', [reset.id]);

    logger.info({ userId: user.id }, 'auth: password reset via OTP');
    res.json({ status: 'ok' });
  } catch (err) { next(err); }
});

module.exports = { router, authMiddleware };
