# ConnectSphere

A native iOS social‑networking app with a dual‑persona (Hobby / Work) model,
communities, real‑time chat, and an AI‑powered semantic search over people and
posts. Built for **COMP1682**.

- **iOS app** — SwiftUI, `@Observable` view models, `URLSession` + a hand‑rolled
  WebSocket client (no third‑party networking).
- **Backend** — Swift + Vapor 4, raw parameterised SQL via SQLKit/PostgresKit
  (no Fluent), PostgreSQL (with `pgvector`), Redis + Vapor Queues for background
  jobs, a Socket.IO v4 / Engine.IO 4 protocol shim on Vapor WebSocket, and a
  local **Ollama** LLM for query understanding and embeddings. *(Ported from
  Node/Express — the retired implementation is in `legacy/backend-node/`, tag
  `node-backend-final`.)*
- **Bilingual** — English / Vietnamese, switchable in‑app.

Who the app is for, what people do in it and what sets it apart:
[`PRODUCT.md`](PRODUCT.md). For how the AI search pipeline works end to end, see
[`AI_SEARCH_OVERVIEW.md`](AI_SEARCH_OVERVIEW.md), and for how it compares with Spotify, Netflix
and Amazon, see [`AI_SEARCH_REVIEW.md`](AI_SEARCH_REVIEW.md); for how the Home feed ranks posts
compared with Facebook and TikTok, see [`FEED_RANKING_REVIEW.md`](FEED_RANKING_REVIEW.md). For deliberately deferred
scope, see [`KNOWN_GAPS.md`](KNOWN_GAPS.md).

---

## Architecture

```
┌────────────┐     REST + WebSocket      ┌──────────────────────────────┐
│  iOS app   │ ───────────────────────▶  │  Vapor API (server/)          │
│ (SwiftUI)  │ ◀───────────────────────  │  ├─ routes → controllers →    │
└────────────┘                           │  │   stores (raw SQL)         │
                                         │  ├─ Socket.IO v4 shim         │
                                         │  │   (presence, chat, counters)│
                                         │  └─ Vapor Queues workers      │
                                         └───┬───────────┬───────────┬───┘
                                             │           │           │
                                    ┌────────▼──┐  ┌─────▼─────┐  ┌──▼────────┐
                                    │ Postgres  │  │  Redis    │  │  Ollama   │
                                    │ +pgvector │  │ (queues)  │  │ (host)    │
                                    └───────────┘  └───────────┘  └───────────┘
```

- `server/Sources/App/` is layered **routes → controllers → stores**; the
  `Stores/` (and `AI/`) files are the only place raw SQL lives
  (`Infra/AppDatabase.swift` — `sql()` / `withTransaction`).
- Background work (tag extraction → chunk embedding chain, daily cleanup,
  birthday / meeting reminders, post purge, trending) runs in
  `server/Sources/App/Jobs/` (gated by `RUN_JOBS=1`).
- The 27 `backend/migrations/*.sql` files are unchanged and replayed at boot by
  `Infra/MigrationRunner.swift` (advisory-locked, idempotent).
- `server/contract/` diffs every endpoint's normalised JSON against a running
  copy of the old Node backend — 179 checks across 8 suites.
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

# 3. Bring up Postgres + Redis + the Swift backend (migrations run at boot)
./dev.sh start
#    (or manually:  cd backend && docker compose up -d --build)
#    First run builds the Swift release image — slow; later runs cache.
#    For a fast inner loop, run the server on the host instead:
#      cd server && PORT=3000 swift run App serve          # reads ../backend/.env

# 4. Open the iOS app
open ConnectSphere.xcodeproj      # then Run on an iOS 17+ simulator
```

`./dev.sh start` also opens Xcode / VS Code / TablePlus; `./dev.sh stop` tears
everything down. The script derives its own path, so it runs from any checkout
location.

## Tests

```bash
# Backend contract checks — diff the Vapor port against the retired Node oracle.
# Needs the Node backend running on :3000 as the oracle:
#   cd legacy/backend-node && npm install && DB_HOST=localhost npm start   # :3000
#   cd server && PORT=8080 swift run App serve                             # :8080
bash server/contract/phase2.sh          # etc. — see server/contract/

# Backend unit tests
cd server && swift test

# iOS unit tests
xcodebuild test -scheme ConnectSphere \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ConnectSphereTests
```

## Operational notes

- `GET /health` reports the liveness of Postgres, Redis, and Ollama.
- Migrations run at boot in filename order, each wrapped in a transaction, under
  a Postgres advisory lock (`Infra/MigrationRunner.swift`). There are no
  down‑migrations — take a `pg_dump` before a risky one. `RUN_MIGRATIONS=1`
  (set by docker-compose) enables the boot replay.
- The retired Node backend is in `legacy/backend-node/` (tag `node-backend-final`)
  — kept as a reference and a contract-test oracle, not part of the running stack.
- `docker compose down` (no `-v`) stops everything and **keeps** data; `-v`
  would wipe the `postgres_data` / `redis_data` volumes.

## Known limitations

Push notifications (APNs) are not implemented — in‑app notifications work, but
nothing arrives while the app is closed. The iOS error‑state rollout and a few
backend query optimisations are partial. See
[`KNOWN_GAPS.md`](KNOWN_GAPS.md) for the full list with reasoning.
