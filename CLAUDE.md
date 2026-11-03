# ConnectSphere

A native iOS social networking app (COMP1682 project) with a **Swift/Vapor 4** backend
(`server/`), ported from Node/Express (retired to `legacy/backend-node/`, tag
`node-backend-final`). Raw parameterised SQL via SQLKit/PostgresKit — no Fluent.
Notable feature: an AI-powered semantic search over users/posts using a local LLM
query pipeline and chunk-based pgvector embeddings — see `AI_SEARCH_OVERVIEW.md`.

## Running it
- `./dev.sh start` — Docker (`backend/docker-compose.yml`: Postgres + Redis + the Swift backend container, name `connectsphere_backend`, port 3000) + host Ollama + opens Xcode
- `backend/` is now the infra dir: `docker-compose.yml`, `.env`, `migrations/` (the 27 shared SQL files), `uploads/`
- Migrations replay at boot (`RUN_MIGRATIONS=1`, advisory-locked); no separate migrate step
- Fast inner loop: `cd server && PORT=3000 swift run App serve` (host, reads `../backend/.env`)
- Contract tests: `server/contract/*.sh` diff the port against a Node oracle on :3000 — 179 checks, 8 suites

## Product
Who the app is for, what people do in it and what sets it apart: see
[`PRODUCT.md`](PRODUCT.md). Keep its product principles when adding features.

## Architecture
iOS app is MVVM (views → `@Observable` ViewModels → repositories); backend is
Controller → Service/Store → SQL. See [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Known gaps
Deliberately deferred scope (e.g. push notifications) is tracked in [`KNOWN_GAPS.md`](KNOWN_GAPS.md) — check it before assuming a missing feature is an oversight.

## Reading the user's messages
The user separates requests with punctuation:
- **`,`** joins details of the *same* idea / function / feature.
- **`;`** ends that idea and starts a *new* one (it plays the role of `.`).

So "a, b, c; d, e" is two requests: one about a (with details b and c), one
about d (with detail e). Treat each `;`-separated part as its own item
(its own task-list step), and keep the `,` parts together.

## Rules
Detailed working rules live under `.claude/rules/` — read what's relevant to the task:
- [`interaction.md`](.claude/rules/interaction.md) — clarify-before-acting / confirm-before-each-action protocol
- [`code-conventions.md`](.claude/rules/code-conventions.md) — naming, error handling, general coding rules
- [`security.md`](.claude/rules/security.md) — secrets, auth, input validation
- [`memory.md`](.claude/rules/memory.md) — agentmemory skills (`remember`, `recall`, `recap`, `handoff`, `forget`)
