# ConnectSphere — Swift backend (Vapor)

Port of `../backend` (Node/Express) to Swift, talking to the **same** PostgreSQL
database. Raw parameterized SQL via SQLKit/PostgresKit — no Fluent. See
`~/.claude/plans/zesty-honking-mitten.md` for the full plan.

## Run (local dev)

Postgres + Redis come from `../backend/docker-compose.yml` (`./dev.sh start` at
the repo root). The Swift server reads `../backend/.env` for config.

```bash
cd server
swift run App serve                      # port from .env (3000) — clashes with Node
PORT=8080 swift run App serve             # run alongside the Node backend
RUN_MIGRATIONS=1 PORT=8080 swift run App serve   # replay backend/migrations/*.sql first
```

Env knobs specific to this port:
- `DOTENV_PATH` — path to the `.env` to load (default `../backend/.env`).
- `RUN_MIGRATIONS=1` — run pending migrations at boot.
- `MIGRATIONS_DIR` — override the migrations directory (default `<cwd>/../backend/migrations`).

## Test

```bash
swift test
```

## Contract tests (diff against the Node oracle)

With the Node backend on `:3000` and this server on `:8080`:

```bash
node contract/diff.mjs contract/cases/phase0.json     # ORACLE_BASE / PORT_BASE override the hosts
```

## Docker

```bash
docker compose -f ../docker-compose.swift.yml up --build   # server on :3001, its own PG/Redis
```

## Layout

- `Sources/App/Infra/` — env, DB pool, migration runner, error + security + rate-limit middleware
- `Sources/App/Controllers/` — route handlers (grows one plan phase at a time)
- `Sources/App/Realtime/` — Socket.IO v4 shim (Phase 4)
- `Sources/App/Stores/` — raw-SQL data access, mirrors `../backend/src/models/`
