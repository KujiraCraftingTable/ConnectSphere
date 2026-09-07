# ConnectSphere

A native iOS social networking app (COMP1682 project) with a Node.js/Express backend.
Notable feature: an AI-powered semantic search over users/posts using a local LLM
query pipeline and chunk-based pgvector embeddings — see `AI_SEARCH_OVERVIEW.md`.

## Running it
- `./dev.sh start` — Docker (`backend/docker-compose.yml`: Postgres + Redis + the backend container) + host Ollama + opens Xcode
- Backend runs in a container in dev mode with hot reload; run migrations with `cd backend && docker compose exec backend npm run migrate`

## Known gaps
Deliberately deferred scope (e.g. push notifications) is tracked in [`KNOWN_GAPS.md`](KNOWN_GAPS.md) — check it before assuming a missing feature is an oversight.

## Rules
Detailed working rules live under `.claude/rules/` — read what's relevant to the task:
- [`interaction.md`](.claude/rules/interaction.md) — clarify-before-acting / confirm-before-each-action protocol
- [`code-conventions.md`](.claude/rules/code-conventions.md) — naming, error handling, general coding rules
- [`security.md`](.claude/rules/security.md) — secrets, auth, input validation
- [`memory.md`](.claude/rules/memory.md) — agentmemory skills (`remember`, `recall`, `recap`, `handoff`, `forget`)
