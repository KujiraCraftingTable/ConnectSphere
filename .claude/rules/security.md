# Security Rules

## Backend
- NEVER hardcode secrets; all secrets go in `.env`, never committed to git
- Always keep `.env` in `.gitignore`; provide `.env.example` with dummy values
- Use bcrypt for password hashing (min 12 rounds)
- Use JWT for auth (access token short-lived, refresh token if needed)
- Sanitize and validate all inputs (use express-validator or zod)
- Enable helmet.js and rate limiting on all public routes
- Database queries must use parameterized statements — no string interpolation

## iOS
- Store tokens in Keychain, never in UserDefaults
- Never log sensitive data (tokens, passwords, PII)
- Use HTTPS only; enforce with App Transport Security
