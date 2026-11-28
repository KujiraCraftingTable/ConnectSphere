# ConnectSphere, Swift backend (Vapor)

The Swift/Vapor 4 backend. It owns the PostgreSQL
schema in `../backend/migrations/`. Raw parameterized SQL via
SQLKit/PostgresKit, no Fluent. Overview: `../README.md`, layering:
`../ARCHITECTURE.md`.

## Setup on a new machine

A fresh clone gets the code and the database schema. It doesn't get anyone's
secrets (`backend/.env`), data (the Postgres volume, `backend/uploads/`) or AI
models, so it starts with an empty app.

### 1. Install
- Docker Desktop
- [Ollama](https://ollama.com), running on the machine itself, not in Docker
- For the iOS app: a Mac with Xcode and an iOS simulator
- To run the server outside Docker: Swift 5.10 or newer (comes with Xcode)

### 2. Pull the AI models
```bash
ollama pull qwen2.5:7b-instruct-q4_k_m   # search prompts, translation, AI tags
ollama pull mxbai-embed-large            # embeddings for AI search
```
Without them the app still runs, but AI search, translation and embeddings don't.

### 3. Create `backend/.env`
```bash
cp backend/.env.example backend/.env
```
Then edit it:
- `JWT_SECRET`: required. Generate one with `openssl rand -hex 32`
- `BREVO_API_KEY`: leave it unset. Email codes are then written to the server log instead of sent
- `GOOGLE_CLIENT_ID`: only for Google sign-in. Username and password sign-in work without it
- Leave the rest as it is; the DB and Redis defaults match `docker-compose.yml`

### 4. Start the backend
Pick one of these.

**Everything in Docker**: Postgres, Redis and this server.
```bash
cd backend && docker compose up -d --build
```

**Server on the host** (faster to rebuild, what `../dev.sh start` does):
```bash
cd backend && docker compose up -d postgres redis
cd ../server && RUN_MIGRATIONS=1 RUN_JOBS=1 PORT=3000 swift run App serve
```

Either way the migrations create every table on first boot. Check it's up:
`curl http://localhost:3000/health`.

### 5. Add demo content (optional)
The database starts empty. To add the 40 demo people and the communities, run
these from `server/` (needs Swift on the host, Postgres up, and Ollama for `embed`):
```bash
swift run App seed-demo seed
swift run App seed-demo embed
swift run App seed-demo communities --commit
```

### 6. Run the iOS app
Open `ConnectSphere.xcodeproj`, set your own Team under Signing & Capabilities,
and run the `ConnectSphere` scheme on a simulator. The simulator always talks
to `http://localhost:3000`. Sign up for a new account in the app.

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
cd ../backend && docker compose up -d --build   # Postgres + Redis + this server
cd ../backend && docker compose up -d postgres redis   # infra only, server on the host
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
