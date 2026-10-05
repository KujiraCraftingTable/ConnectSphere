# Code Conventions

## Naming

### Backend (Swift/Vapor)
- Files & types: PascalCase (`PostsController.swift`, `UserStore`)
- Variables/functions: camelCase
- DB tables & columns: snake_case (`user_profiles`, `application_deadline`)
- JSON keys: snake_case, matching the column names (`post_type`, `is_liked`)
- Routes: kebab-case (`/api/check-username`)

### iOS (SwiftUI)
- Files & Types: PascalCase (`ExpenseListView`, `UserViewModel`)
- Variables/functions: camelCase
- Constants: camelCase in enum/struct, UPPER_SNAKE_CASE only for global
- Follow Apple's Swift API Design Guidelines

## Error handling & logging

### Backend (Swift/Vapor)
- Throw `Abort(.badRequest, reason: "...")` or `InlineError(.badRequest, "...")`; let the
  error propagate rather than catching and re-wrapping
- `AppErrorMiddleware` (`Sources/App/Infra/`) is the central handler — it renders the
  consistent JSON shape the iOS client parses:
  `{ "status": "error", "code": 400, "message": "..." }`
- Use Vapor's `Logger` (`req.logger`), never `print` on a request path
- Fire-and-forget side effects (notifications, embeddings) must not fail the request —
  detach them, following `NotifyService.fireAndForget`

### iOS
- Use `Result<T, Error>` or `async throws` consistently
- Never show raw error messages to the user; map errors to user-friendly strings
- Log errors in DEBUG builds only (`print` / `Logger` framework)

## General
- Write code in English (variable names, comments, file names)
- Comment the *why*, not the what — a non-obvious constraint, a subtle invariant, a
  workaround and the bug it works around. Well-named code doesn't need narration
- No dead code, no TODO left uncommitted
- Each feature must be complete (model + service + route + controller) before moving to the next
- Ask before installing any new dependency (SPM in `server/Package.swift`, or Xcode SPM)
