# ConnectSphere

A native iOS social networking app (COMP1682 project) with a Node.js/Express backend.
Notable feature: an AI-powered semantic search over users/posts using a local LLM
query pipeline and chunk-based pgvector embeddings — see `AI_SEARCH_OVERVIEW.md`.

## Stack
- **iOS**: SwiftUI, @Observable view models, MVVM-ish (`Core/` + `Features/`), localized EN/VI
- **Backend**: Node.js + Express, Socket.io (realtime), BullMQ + Redis (jobs), JWT auth
- **Database**: PostgreSQL + pgvector (HNSW cosine search for embeddings)

## Structure
```
ConnectSphere/          # iOS app (SwiftUI)
  Auth/                 # Login, Register, onboarding
  Core/                 # Network, Data, Theme, Extensions, shared UI
  Features/             # Feed, Chat, Communities, Search, Notifications, Profile, Settings
backend/
  src/
    config/             # DB connection, env config
    controllers/        # Route handler logic
    middlewares/        # Auth, error handler, logging
    models/             # PostgreSQL query models
    routes/             # Express routers
    services/           # Business logic layer
    queues/ jobs/        # BullMQ background jobs
    utils/              # Helpers, constants
  migrations/           # SQL migrations (001..027)
  scripts/              # Seeding, geocoding, embedding tooling
```

## Running it
- `./dev.sh start` — brings up Docker (Postgres), backend, and opens the Xcode project
- `backend/`: `npm run dev` (nodemon), `npm run migrate`, `npm run seed`

## Rules
Detailed working rules live under `.claude/rules/` — read what's relevant to the task:
- [`interaction.md`](.claude/rules/interaction.md) — clarify-before-acting / confirm-before-each-action protocol
- [`code-conventions.md`](.claude/rules/code-conventions.md) — naming, error handling, general coding rules
- [`security.md`](.claude/rules/security.md) — secrets, auth, input validation
- [`memory.md`](.claude/rules/memory.md) — agentmemory skills (`remember`, `recall`, `recap`, `handoff`, `forget`)
