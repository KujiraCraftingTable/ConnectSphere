# ConnectSphere

A native iOS social‑networking app with a dual‑persona (Hobby / Work) model,
communities, real‑time chat, and an AI‑powered semantic search over people and
posts. Built for **COMP1682**.

- **iOS app** — SwiftUI, `@Observable` view models, `URLSession` + a hand‑rolled
  WebSocket client (no third‑party networking).
- **Backend** — Node.js + Express, PostgreSQL (with `pgvector`), Redis + BullMQ
  for background jobs, and a local **Ollama** LLM for query understanding and
  embeddings.
- **Bilingual** — English / Vietnamese, switchable in‑app.

For how the AI search pipeline works end to end, see
[`AI_SEARCH_OVERVIEW.md`](AI_SEARCH_OVERVIEW.md). For deliberately deferred
scope, see [`KNOWN_GAPS.md`](KNOWN_GAPS.md).

---

## Architecture

```
┌────────────┐     REST + WebSocket      ┌──────────────────────────────┐
│  iOS app   │ ───────────────────────▶  │  Express API (backend/)       │
│ (SwiftUI)  │ ◀───────────────────────  │  ├─ routes → controllers →    │
└────────────┘                           │  │   services → models        │
                                         │  ├─ Socket.IO (presence,      │
                                         │  │   chat, live counters)     │
                                         │  └─ BullMQ workers            │
                                         └───┬───────────┬───────────┬───┘
                                             │           │           │
                                    ┌────────▼──┐  ┌─────▼─────┐  ┌──▼────────┐
                                    │ Postgres  │  │  Redis    │  │  Ollama   │
                                    │ +pgvector │  │ (queues)  │  │ (host)    │
                                    └───────────┘  └───────────┘  └───────────┘
```

- `backend/src/` is layered **routes → controllers → services → models**; models
  are the only place raw SQL lives (`src/config/db.js` `query` / `withTransaction`).
- Background work (tag extraction, chunk embedding, daily cleanup, birthday /
  meeting reminders, post purge) runs in `src/jobs/` and `src/queues/`.
- The iOS app mirrors the layering: `Features/<X>/{Views,ViewModels,Repository,Models}`
  with shared infrastructure in `Core/`.

## Quick start

**Prerequisites:** Docker Desktop, Xcode 16+, and [Ollama](https://ollama.com)
installed on the host (Docker on Apple Silicon can't pass the GPU to a
container, so Ollama stays on the host).

```bash
git clone <repo> && cd ConnectSphere

# 1. Backend env
cp backend/.env.example backend/.env
#    then edit backend/.env — set at least JWT_SECRET (`openssl rand -hex 32`)
#    and, for Google sign‑in, GOOGLE_CLIENT_ID.

# 2. Pull the two models the AI pipeline needs
ollama pull qwen2.5:7b-instruct-q4_k_m
ollama pull mxbai-embed-large

# 3. Bring up Postgres + Redis + the backend, run migrations
./dev.sh start
#    (or manually:  cd backend && docker compose up -d --build
#                   && docker compose exec backend npm run migrate)

# 4. Open the iOS app
open ConnectSphere.xcodeproj      # then Run on an iOS 17+ simulator
```

`./dev.sh start` also opens Xcode / VS Code / TablePlus; `./dev.sh stop` tears
everything down. The script derives its own path, so it runs from any checkout
location.

Seed some demo data (optional): `cd backend && docker compose exec backend npm run seed`

## Tests

```bash
# Backend (Node's built‑in test runner, all mocked — no live DB needed)
cd backend && docker compose exec backend npm test

# iOS unit tests
xcodebuild test -scheme ConnectSphere \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ConnectSphereTests
```

CI (`.github/workflows/ci.yml`) runs both on every push, with coverage enabled.

## Operational notes

- `GET /health` reports the liveness of Postgres, Redis, and Ollama.
- `node backend/scripts/reconcile-counters.js` recomputes every denormalised
  `*_count` column from source rows (`--dry-run` to just report drift).
- Migrations run in filename order and are each wrapped in a transaction by
  `scripts/migrate.js`. There are no down‑migrations — take a `pg_dump` before a
  risky one.
- `docker compose down` (no `-v`) stops everything and **keeps** data; `-v`
  would wipe the `postgres_data` / `redis_data` volumes.

## Known limitations

Push notifications (APNs) are not implemented — in‑app notifications work, but
nothing arrives while the app is closed. The iOS error‑state rollout and a few
backend query optimisations are partial. See
[`KNOWN_GAPS.md`](KNOWN_GAPS.md) for the full list with reasoning.
