# ConnectSphere

A native iOS social networking app (COMP1682 project) with a Swift/Vapor 4 backend
(`server/`). Notable feature: an AI-powered semantic search over users/posts using a local LLM
query pipeline and chunk-based pgvector embeddings. See `AI_SEARCH_OVERVIEW.md`.
Start with `README.md`; layering rules are in `ARCHITECTURE.md`, deferred scope in `KNOWN_GAPS.md`.

## Stack
- **iOS**: SwiftUI, @Observable view models, strict MVVM (`Core/` + `Features/`), localized EN/VI
- **Backend**: Swift + Vapor 4, raw SQL via SQLKit/PostgresKit (no Fluent), Socket.IO shim for realtime, Vapor Queues + Redis (jobs), JWT auth, local Ollama
- **Database**: PostgreSQL + pgvector (HNSW cosine search for embeddings)

## Structure
```
ConnectSphere/          # iOS app (SwiftUI)
  Auth/                 # Login, Register, forgot password
  Core/                 # Network, Persistence, Theme, shared UI/components, ViewModels
  Features/             # Feed, Chat, Communities, Marketplace, Companies, Jobs, WorkProfile,
                        # Search, Notifications, Profile, Settings, Onboarding, Assistant
server/Sources/App/     # Vapor backend
  Controllers/ Stores/ Services/ AI/ Jobs/ Realtime/ Infra/ Commands/
backend/                # infra: docker-compose.yml, .env, migrations/ (001..097), uploads/
legacy/                 # archived Dating space (not built)
```

## Running it
- `./dev.sh start`, Docker (Postgres + Redis), host Ollama, the Swift backend on the host (:3000), then opens Xcode
- Backend only: `cd server && RUN_MIGRATIONS=1 RUN_JOBS=1 PORT=3000 swift run App serve`
- Tests: `cd server && swift test`; iOS via `xcodebuild test -scheme ConnectSphere -only-testing:ConnectSphereTests`

## Rules
Detailed working rules live under `.claude/rules/`. Read what's relevant to the task:
- [`interaction.md`](.claude/rules/interaction.md), clarify-before-acting / confirm-before-each-action protocol
- [`code-conventions.md`](.claude/rules/code-conventions.md), naming, error handling, general coding rules
- [`security.md`](.claude/rules/security.md), secrets, auth, input validation
- [`memory.md`](.claude/rules/memory.md), agentmemory skills (`remember`, `recall`, `recap`, `handoff`, `forget`)
