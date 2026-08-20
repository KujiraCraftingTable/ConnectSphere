# Code Conventions

## Naming

### Backend
- Files: camelCase (`userController.js`, `authMiddleware.js`)
- Variables/functions: camelCase
- Constants: UPPER_SNAKE_CASE
- DB tables: snake_case (`user_profiles`, `expense_items`)
- Routes: kebab-case (`/api/expense-items`)

### iOS (SwiftUI)
- Files & Types: PascalCase (`ExpenseListView`, `UserViewModel`)
- Variables/functions: camelCase
- Constants: camelCase in enum/struct, UPPER_SNAKE_CASE only for global
- Follow Apple's Swift API Design Guidelines

## Error handling & logging

### Backend
- All controllers must use try/catch and pass errors to `next(err)`
- Central error handler middleware in `middlewares/errorHandler.js`
- Log format: `[LEVEL] [timestamp] message` — use a logger (winston or pino), never `console.log` in production
- HTTP errors must return consistent JSON:
  `{ "status": "error", "code": 400, "message": "..." }`

### iOS
- Use `Result<T, Error>` or `async throws` consistently
- Never show raw error messages to the user; map errors to user-friendly strings
- Log errors in DEBUG builds only (`print` / `Logger` framework)

## General
- Write code in English (variable names, comments, file names)
- Every function/method must have a brief comment explaining its purpose
- No dead code, no TODO left uncommitted
- Each feature must be complete (model + service + route + controller) before moving to the next
- Ask before installing any new dependency
