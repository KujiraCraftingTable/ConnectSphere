# ConnectSphere

A native iOS social-networking app with a dual-persona (Hobby / Work) model,
communities with a built-in marketplace, real-time chat, Work-mode careers and
an AI-powered semantic search over people and posts. Built for **COMP1682**.

- **iOS app**, SwiftUI, MVVM with `@Observable` ViewModels, `URLSession` plus
  a hand-rolled Socket.IO WebSocket client. Deployment target iOS 18.0.
  English / Vietnamese, switchable in-app.
- **Backend** (`server/`), Swift + Vapor 4, raw parameterised SQL via
  SQLKit/PostgresKit (no Fluent), PostgreSQL 16 + `pgvector`, Redis + Vapor
  Queues for background jobs, a Socket.IO v4 shim on Vapor WebSocket, and a
  local **Ollama** LLM for query understanding, embeddings and translation.

Further reading: [`PRODUCT.md`](PRODUCT.md) (who it is for, what it does),
[`ARCHITECTURE.md`](ARCHITECTURE.md) (layering and the MVVM rule),
[`AI_SEARCH_OVERVIEW.md`](AI_SEARCH_OVERVIEW.md) (AI search pipeline),
[`AI_SEARCH_REVIEW.md`](AI_SEARCH_REVIEW.md) and
[`FEED_RANKING_REVIEW.md`](FEED_RANKING_REVIEW.md) (comparisons with large
platforms), [`KNOWN_GAPS.md`](KNOWN_GAPS.md) (deliberately deferred scope).

## What is in the app

Hobby and Work are separate datasets everywhere (feed, connections, search,
communities, chat inbox).

- **Feed and posts**, photos/videos, hashtags, polls, per-post privacy,
  drafts and scheduled posts, stories and profile highlights, saved posts,
  EN↔VI translation of posts and comments, muted words, report and
  "hide all from this person".
- **Profiles**, Hobby profile (About, details, schools, highlights, lock
  profile) and Work profile (experience, skills with endorsements); flip a
  person's card to their other persona.
- **Chat**, direct and group chats, albums, voice, polls, meeting proposals
  with reminders, message requests, inbox *Spaces*, archive.
- **Communities**, per-mode discovery, cover and info pages, post approval,
  notification levels, sharing, "Manage your content", reports and a
  moderation queue per community.
- **Marketplace**, listings (photos, price, map location) that also appear
  as posts in up to 5 communities; re-up (manual and automatic), seller
  auto-reply, hide from friends, mark as sold.
- **Work careers**, company pages, jobs tab (recommended, search, saved),
  Easy Apply with applicant tracking.
- **AI search and assistant**, natural-language search, "People you may
  know", an in-app assistant.
- **Account**, saved accounts on the device, sign in with email or
  `@username`, Google sign-in, email codes, two-factor sign-in, privacy and
  security settings, in-app browser for links, deleting a persona or the
  account.
- **Not live:** the 16+ Dating space was archived on 2026-11-05 and lives in
  `legacy/dating/` (see its README). Push notifications are not implemented.

## Repository layout

```
ConnectSphere/          iOS app: Auth/, Core/ (network, theme, shared UI,
                        persistence), Features/<X>/{Views,ViewModels,Repository,Models}
ConnectSphereTests/     iOS unit tests (Swift Testing)
ConnectSphereUITests/   UI tests
server/                 Vapor backend: Sources/App/{Controllers,Stores,Services,AI,
                        Jobs,Realtime,Infra,Commands}, Tests/AppTests
backend/                infra: docker-compose.yml, .env(.example), migrations/, uploads/
legacy/                 archived Dating space (not built)
scripts/                lint-design.sh (design-token budget check)
dev.sh                  start / stop the whole local stack
```

## Quick start

**Prerequisites:** Docker Desktop, Xcode, and [Ollama](https://ollama.com) on
the host (Docker on Apple Silicon can't pass the GPU through).

```bash
cp backend/.env.example backend/.env
#   set at least JWT_SECRET (`openssl rand -hex 32`); GOOGLE_CLIENT_ID for Google sign-in.
#   Leave BREVO_API_KEY unset in dev: email codes are logged instead of sent.

./dev.sh start
```

`./dev.sh start` starts Docker (Postgres + Redis only), Ollama (pulling
`qwen2.5:7b-instruct-q4_k_m` and `mxbai-embed-large` on first run), runs the
Swift backend **on the host** on port 3000 with `RUN_MIGRATIONS=1 RUN_JOBS=1`
(log: `/tmp/connectsphere-server.log`), then opens Xcode, VS Code and
TablePlus. `./dev.sh stop` shuts it all down. Then run the `ConnectSphere`
scheme on an iOS simulator.

Fast inner loop without the script (Postgres and Redis already up):

```bash
cd server && RUN_MIGRATIONS=1 RUN_JOBS=1 PORT=3000 swift run App serve   # reads ../backend/.env
```

`backend/docker-compose.yml` also defines a `backend` service (the Swift
server in a container) for `docker compose up -d --build`, but `dev.sh` does
not use it.

## Database and migrations

- `backend/migrations/` holds 92 SQL files, numbered `001`–`097` (`089`–`092`
  and `094` do not exist). They are shared by the server and replayed at boot
  in filename order by `Infra/MigrationRunner.swift`, each in a transaction,
  under a Postgres advisory lock.
- The replay only happens with `RUN_MIGRATIONS=1` (`dev.sh` and the compose
  file set it). A server started without it will not apply new migrations.
- There are no down-migrations: `pg_dump` before a risky one.
- `docker compose down` keeps data; `-v` wipes the `postgres_data` / `redis_data` volumes.
- `RUN_JOBS=1` enables background jobs: tag extraction and chunk embedding,
  the 30-minute chunk sweep, scheduled-post publishing, auto re-up,
  translation, meeting reminders and daily housekeeping
  (`server/Sources/App/Jobs/BackgroundJobs.swift`).

## Tests

```bash
# Backend unit tests
cd server && swift test

# iOS unit tests (pick any installed simulator)
xcodebuild test -project ConnectSphere.xcodeproj -scheme ConnectSphere \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ConnectSphereTests

# Design-token budget check
bash scripts/lint-design.sh
```

The MVVM rule check (must print nothing) is in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Other commands

`GET /health` reports Postgres, Redis and Ollama. The server binary also has
maintenance commands (`swift run App <name>`, defined in
`server/Sources/App/Commands/`): `seed-demo` (wipe, seed and embed demo
people; `seed-demo communities` replaces all communities and listings with the
6 in `server/Seeds/demo-communities.json`; use `--commit`), `strip-upload-metadata`, `verify-company`,
`community-reports`.
