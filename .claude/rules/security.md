# Security Rules

## Backend (Swift/Vapor)
- NEVER hardcode secrets; all secrets go in `backend/.env`, never committed to git
- Always keep `.env` in `.gitignore`; provide `.env.example` with dummy values
- Use bcrypt for password hashing (min 12 rounds)
- Use JWT for auth (`JWTHS256` + `AuthMiddleware`); `req.userID` is the lowercased subject
- Validate every input explicitly after decoding it into a `Content` struct — check
  enums against an allowlist (`guard ["hobby","work"].contains(mode)`) and bound lengths
  before they reach SQL
- `SecurityHeadersMiddleware` and `RateLimitMiddleware` are already registered in
  `configure.swift`; put new auth-adjacent routes behind the rate limiter
- Database queries must use parameterised interpolation — `\(bind:)` for values,
  `\(uuid:)` for UUIDs. `\(unsafeRaw:)` only for literals already validated against an
  allowlist, never for user input

## iOS
- Store tokens in Keychain, never in UserDefaults
- Never log sensitive data (tokens, passwords, PII)
- Use HTTPS only; enforce with App Transport Security
