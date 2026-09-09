// Validates required environment variables at startup
const REQUIRED = [
  'DB_HOST', 'DB_PORT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD',
];

// Values that are placeholders, not real secrets — anyone running with one of
// these can forge a token for any user, so production must not boot with them.
const WEAK_JWT_SECRETS = new Set([
  'dev_secret',
  'change-me-generate-with-openssl-rand-hex-32',
]);

function validateEnv() {
  const missing = REQUIRED.filter((key) => !process.env[key]);
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }

  const jwtSecret = process.env.JWT_SECRET;
  const weakJwt = !jwtSecret || WEAK_JWT_SECRETS.has(jwtSecret);
  if (process.env.NODE_ENV === 'production') {
    if (weakJwt) {
      throw new Error('JWT_SECRET must be set to a strong, unique value in production');
    }
    if (!process.env.GOOGLE_CLIENT_ID) {
      // eslint-disable-next-line no-console
      console.warn('[env] GOOGLE_CLIENT_ID is not set — Google sign-in will be refused');
    }
  } else if (weakJwt) {
    // eslint-disable-next-line no-console
    console.warn('[env] JWT_SECRET is unset or a placeholder — fine for local dev, never deploy like this');
  }
}

module.exports = {
  validateEnv,
  PORT: process.env.PORT || 3000,
  NODE_ENV: process.env.NODE_ENV || 'development',
  jwt: {
    secret:    process.env.JWT_SECRET    || 'dev_secret',
    expiresIn: process.env.JWT_EXPIRES_IN || '90d',
  },
  google: {
    clientId: process.env.GOOGLE_CLIENT_ID || '',
  },
  // SMTP for the forgot-password OTP. Unset user/pass → mailerService logs the
  // OTP instead of sending (dev/CI). Vars match .env.example (SMTP_*/MAIL_FROM).
  mail: {
    host: process.env.SMTP_HOST || 'smtp.gmail.com',
    port: parseInt(process.env.SMTP_PORT || '587', 10),
    user: process.env.SMTP_USER || '',
    pass: process.env.SMTP_PASS || '',
    from: process.env.MAIL_FROM || process.env.SMTP_USER || '',
  },
  ollama: {
    url:   process.env.OLLAMA_URL   || 'http://localhost:11434',
    model: process.env.OLLAMA_MODEL || 'qwen2.5:7b-instruct-q4_k_m',
  },
  redis: {
    host: process.env.REDIS_HOST || 'localhost',
    port: parseInt(process.env.REDIS_PORT || '6379', 10),
  },
  db: {
    host: process.env.DB_HOST,
    port: parseInt(process.env.DB_PORT, 10),
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    max: parseInt(process.env.DB_POOL_MAX || '10', 10),
    idleTimeoutMillis: parseInt(process.env.DB_POOL_IDLE_TIMEOUT || '30000', 10),
    connectionTimeoutMillis: parseInt(process.env.DB_POOL_CONNECTION_TIMEOUT || '2000', 10),
  },
};
