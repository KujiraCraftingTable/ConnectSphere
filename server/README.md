# ConnectSphere, Swift backend (Vapor)

The Swift/Vapor 4 backend. It owns the PostgreSQL
schema in `../backend/migrations/`. Raw parameterized SQL via
SQLKit/PostgresKit, no Fluent. Overview: `../README.md`, layering:
`../ARCHITECTURE.md`.

## Run (local dev)

Postgres + Redis come from `../backend/docker-compose.yml` (`./dev.sh start` at
the repo root). The Swift server reads `../backend/.env` for config.

```bash
cd server
RUN_MIGRATIONS=1 RUN_JOBS=1 PORT=3000 swift run App serve   # what dev.sh runs
```

Env knobs specific to this port:
- `DOTENV_PATH`, path to the `.env` to load (default `../backend/.env`).
- `RUN_MIGRATIONS=1`, replay `backend/migrations/*.sql` at boot (advisory-locked). Without it new migrations are not applied.
- `RUN_JOBS=1`, run the Redis-backed queues and scheduled jobs.
- `MIGRATIONS_DIR`, override the migrations directory (default `<cwd>/../backend/migrations`).

## Test

```bash
swift test
```

Maintenance commands: `swift run App seed-demo` (wipe / seed / embed demo
people, `--commit` to apply), `strip-upload-metadata`, `verify-company`,
`community-reports`.

## Docker

```bash
docker compose -f ../docker-compose.swift.yml up --build   # server on :3001, its own PG/Redis
# or the infra stack: cd ../backend && docker compose up -d --build   # :3000
```

## Layout

- `Sources/App/Infra/`, env, DB pool, migration runner, error + security + rate-limit middleware
- `Sources/App/Controllers/`, route handlers, registered in `routes.swift`
- `Sources/App/Stores/`, raw-SQL data access
- `Sources/App/Services/`, `AI/`, notifications, publishing, search / embeddings / translation (Ollama)
- `Sources/App/Jobs/`, Vapor Queues jobs and schedules
- `Sources/App/Realtime/`, Socket.IO v4 shim
- `Sources/App/Commands/`, maintenance commands
- `Tests/AppTests/`, unit tests (`swift test`)
