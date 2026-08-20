/**
 * authRoutes.js
 *
 * POST /api/auth/register        — create account with username + password → return JWT
 * POST /api/auth/login           — verify username + password → return JWT
 * POST /api/auth/google          — verify Google ID token → return JWT
 * GET  /api/auth/me               — return current user from JWT
 * GET  /api/auth/check-username   — realtime check trong lúc onboarding (?username=...)
 * POST /api/auth/setup            — complete onboarding (username, displayName, dob, mode, interests, skills)
 * POST /api/auth/change-password  — đổi mật khẩu (tài khoản Google: đặt lần đầu, không cần mật khẩu cũ)
 * POST /api/auth/forgot-password  — phát OTP 6 số qua email (dev: log console)
 * POST /api/auth/reset-password   — đặt lại mật khẩu bằng OTP
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
const USERNAME_REGEX  = /^[a-z0-9_]{3,30}$/;  // khớp filter bên iOS onboarding
const MIN_PASSWORD_LEN = 8;

// Chặt hơn limiter global (1000/15m): chống brute-force password
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
  // Danh tính top-level (display_name/bio/avatar/cover) resolve theo persona
  // của default_mode — mode app sẽ mở sau login. Kèm cờ setup của cả 2 persona
  // để client biết khi nào cần chặn switch mode bằng form tạo persona.
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
    // Không bao giờ trả hash mật khẩu / google id về client
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
    // Token của tài khoản đã soft-delete mất giá trị ngay dù chưa hết hạn.
    // Message dùng chung với token hỏng để không lộ trạng thái tài khoản.
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
// Tạo tài khoản tối thiểu (username + password); phần hồ sơ còn lại do onboarding
// (POST /auth/setup) lo — giống hệt user Google mới.

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
    // display_name tạm = username (NOT NULL) — user đổi ở bước onboarding
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

    // Tài khoản Google (password_hash rỗng/NULL) không login bằng password được.
    // Trả cùng message với sai password để không lộ username nào tồn tại.
    if (!user || !user.password_hash || user.password_hash === 'SEED_DATA') {
      return res.status(401).json({ error: 'Invalid username or password' });
    }

    const ok = await bcrypt.compare(password, user.password_hash);
    if (!ok) return res.status(401).json({ error: 'Invalid username or password' });

    const token   = signToken(user.id);
    const profile = await getUserById(user.id);

    // Đăng ký xong nhưng thoát trước khi onboarding → login lại vẫn vào onboarding
    res.json({ token, user: profile, is_new_user: !user.is_setup });
  } catch (err) { next(err); }
});

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

// ── GET /api/auth/check-username ──────────────────────────────────────────────
// Realtime availability check gọi trong lúc gõ username ở bước onboarding.
// Trả về { available: boolean } — loại trừ chính user hiện tại (đổi lại username cũ vẫn hợp lệ).

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

    // Bắt buộc birthday (mở khoá age-range filter cho AI search) — không giới
    // hạn tuổi tối thiểu, chỉ cần tồn tại và là ngày hợp lệ trong quá khứ.
    if (!dob?.trim()) return res.status(400).json({ error: 'dob is required' });
    const dobDate = new Date(dob);
    if (Number.isNaN(dobDate.getTime()) || dobDate.getTime() >= Date.now()) {
      return res.status(400).json({ error: 'dob must be a valid past date' });
    }

    // dob_visibility: mặc định private (an toàn) nếu client không gửi
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

    // Update user profile — danh tính onboarding ghi vào persona của mode đã
    // chọn (persona mode kia để trống, lần đầu switch sẽ được hỏi form riêng);
    // cột gốc display_name/bio giữ bản sao làm fallback cho bề mặt không gắn mode.
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

    // Onboarding xong → build profile chunk lần đầu (queue có retry)
    enqueueProfileEmbed(req.userId)
      .catch((err) => logger.warn({ err, userId: req.userId }, 'setup: enqueue profile embed failed'));

    const user = await getUserById(req.userId);
    res.json({ user });
  } catch (err) { next(err); }
});

// ── POST /api/auth/change-password ────────────────────────────────────────────
// Đổi mật khẩu khi đã đăng nhập. Tài khoản Google thuần (chưa có mật khẩu)
// được đặt mật khẩu lần đầu mà không cần current_password.

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
// Nhận username hoặc email. LUÔN trả câu trả lời chung chung để không lộ
// tài khoản nào tồn tại / có email. OTP 6 số hash bcrypt, hết hạn 10 phút,
// mã mới phát ra vô hiệu mọi mã cũ chưa dùng.

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
// Đặt lại mật khẩu bằng OTP. Mọi nhánh sai (user không tồn tại / mã sai /
// mã hết hạn) trả cùng một message để không lộ thông tin.

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
