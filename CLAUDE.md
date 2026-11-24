# ConnectSphere
A native iOS social networking app (COMP1682 project) with a **Swift/Vapor 4** backend
(`server/`). Raw parameterised SQL via SQLKit/PostgresKit. No Fluent.
Notable feature: an AI-powered semantic search over users/posts using a local LLM
query pipeline and chunk-based pgvector embeddings. See `AI_SEARCH_OVERVIEW.md`.

## Running it
- `./dev.sh start`, Docker (`backend/docker-compose.yml`: Postgres + Redis only), host Ollama, the Swift backend **on the host** (port 3000, `RUN_MIGRATIONS=1 RUN_JOBS=1`, log `/tmp/connectsphere-server.log`), then opens Xcode
- `backend/` is the infra dir: `docker-compose.yml`, `.env`, `migrations/` (151 shared SQL files, numbered 001–152; 094 does not exist), `uploads/`
- Migrations replay at boot only with `RUN_MIGRATIONS=1` (advisory-locked); no separate migrate step. A server started without it won't apply new migrations
- Fast inner loop: `cd server && RUN_MIGRATIONS=1 RUN_JOBS=1 PORT=3000 swift run App serve` (host, reads `../backend/.env`)
- Tests: `cd server && swift test`; iOS `xcodebuild test -scheme ConnectSphere -only-testing:ConnectSphereTests` (use the iPhone 17 simulator)

## UI tests
- `scripts/uitest.sh` runs the XCUITest suite (`ConnectSphereUITests/`, 36 tests, ~27 min); add `-only-testing:ConnectSphereUITests/AuthTests` for one class. Needs Postgres + Redis up and the iPhone 17 iOS 27 sim booted
- It starts a private server on **:3001** (`UITEST_HOOKS=1`, random `UITEST_TOKEN`, no mail, no jobs) on the same DB, then checks that no `qa_ui_` account is left. :3000 is never touched
- Test-only routes live in `TestHooksController` (`/api/test/*`): loopback + `X-UITest-Token` only, registered only when `UITEST_HOOKS=1`. They create `qa_ui_<run>_<n>` accounts and fixtures, return email codes, and hard-delete a run (users, content and their uploads)
- The app's test mode (`Core/Testing/UITestMode.swift`, DEBUG only, `-uiTesting`) uses its own Keychain service, defaults suite and cache, so the user's real session on the sim survives a run
- Identifiers: `AXID` (`Core/Testing/AXID.swift`, symlinked into the test target), `<feature>.<screen>.<element>[.<id>]`. Put a row's id on the wrapping Button/NavigationLink: ids inside a button label are hoisted away
- Waits use predicates (`waitToAppear`, `tapWhenReady`), never `sleep`. Page objects in `Screens/`, one class per flow in `Flows/`

## Load test
- `scripts/loadtest.sh` (~10 min) loads the Home feed (`GET /api/feed/recommendations`, 10/25/50 users) and AI search (`POST /api/search/ai`, 1/2/4/8 at once, new and cached queries) on a private **:3002** server, then deletes its `qa_ui_` accounts. Needs Postgres + Redis + Ollama; the generator is `scripts/loadtest.py` (standard-library Python). Steps are set by `LOADTEST_*` env vars
- The per-IP rate limits are raised only when `LOAD_TEST=1` and `UITEST_HOOKS=1` are both set (`RateLimitMiddleware`)
- `LOADTEST_ONLY=search` skips the feed steps. AI search is capped by Ollama on this Mac (~0.5 new searches/s); `OLLAMA_NUM_PARALLEL` 2 or 4 doesn't raise it (measured 2026-11-24, see `AI_SEARCH_OVERVIEW.md` §8)
- `SEARCH_MODEL` (default `OLLAMA_MODEL`) is the model that reads search prompts; check a candidate first with `cd server && swift run App search-criteria-eval Tests/Fixtures/search_criteria_eval.jsonl --compare <model>`

## Product
Who the app is for, what people do in it and what sets it apart: see
[`PRODUCT.md`](PRODUCT.md). Keep its product principles when adding features.

## Architecture
iOS app is MVVM (views → `@Observable` ViewModels → repositories); backend is
Controller → Service/Store → SQL. See [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Design
Looks the user has approved (e.g. the profile cover photo's fade) are in
[`DESIGN.md`](DESIGN.md). Keep them unless asked to change one.

## Known gaps
Deliberately deferred scope (e.g. push notifications; the Dating space is archived in `legacy/dating/`, kept outside the repository) is tracked in [`KNOWN_GAPS.md`](KNOWN_GAPS.md). Check it before assuming a missing feature is an oversight.

## Reading the user's messages
The user separates requests with punctuation:
- **`,`** joins details of the *same* idea / function / feature.
- **`;`** ends that idea and starts a *new* one (it plays the role of `.`).

So "a, b, c; d, e" is two requests: one about a (with details b and c), one
about d (with detail e). Treat each `;`-separated part as its own item
(its own task-list step), and keep the `,` parts together.

## Rules
Detailed working rules live under `.claude/rules/`. Read what's relevant to the task:
- [`interaction.md`](.claude/rules/interaction.md), clarify-before-acting / confirm-before-each-action protocol
- [`code-conventions.md`](.claude/rules/code-conventions.md), naming, error handling, general coding rules
- [`security.md`](.claude/rules/security.md), secrets, auth, input validation
- `memory.md` (kept locally, not in the repository), agentmemory skills (`remember`, `recall`, `recap`, `handoff`, `forget`)

## Context saving
- Before reading an entire file, search with grep and read only what you need.
- To explore the project, use a sub-agent and bring me just the summary.
- Show me the diff, not the full file.
- Don't repeat what we've already decided in this session.
- Warns you when it's time to compact or start from scratch
- Short responeses by default.
