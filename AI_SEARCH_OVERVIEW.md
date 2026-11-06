# AI Search, How It Works (ConnectSphere)

> A reading guide, not a design document. Every description reflects the current code.
> For a comparison with Spotify / Netflix / Amazon and the upgrade plan, see [`AI_SEARCH_REVIEW.md`](AI_SEARCH_REVIEW.md).
> Updated 2026-07-04: chunk-based retrieval + a new query pipeline
> (Normalizer → Extractor → Query Builder), with English normalization on both sides.
>
> **Updated 2026-11:** search also has a post-only endpoint (`POST /api/search/ai/posts`), a cached criteria step (migration 086),
> logged search sessions/events (079) and a curated interest catalogue (080); the Home feed
> ranks with impressions and feedback (076–077), capped at 400 candidates from the last 60 days.

---

## 1. Architecture overview

```
[iOS App]  →  POST /api/search/ai  →  [Backend]
                                           │
                      ┌────────────────────▼────────────────────┐
                      │  QUERY UNDERSTANDING (LLM, qwen2.5)      │
                      │  Stage 1 · Normalizer (1 call)           │
                      │    translate to EN + strip noise + mode + │
                      │    has_entity + target_gender            │
                      │  Stage 2 · Extractor (2 parallel calls)  │
                      │    Entity Extractor | Semantic Extractor │
                      └────────────────────┬────────────────────┘
                                           │ criteria
                      ┌────────────────────▼────────────────────┐
                      │  QUERY BUILDER (plain code, 3 branches) │
                      │  entity → canonical / direct;            │
                      │  general → interests+skills              │
                      │  → entityVec + generalVec (in parallel)  │
                      └────────────────────┬────────────────────┘
                                           │
                      ┌────────────────────▼────────────────────┐
                      │  CHUNK RETRIEVAL (pgvector HNSW)         │
                      │  top-k chunks → group by user →          │
                      │  score → rerank → weighted merge         │
                      └────────────────────┬────────────────────┘
                                           │
              [iOS App] ← users + criteria + reasoning + entity_suggestions
```

Two core differences from the old design:

1. **There is no single `users.embedding` any more**. Each user is **many chunks** in
   `user_embedding_chunks`, and the overall score is aggregated from the matching chunks.
2. **Both the query and the chunks are normalized to English** before embedding, because
   `mxbai-embed-large` is weak at Vietnamese. Both sides must meet in the same space.

---

## 2. The `user_embedding_chunks` table

**Schema:** `backend/migrations/001_init.sql`

| Column | Meaning |
|---|---|
| `user_id` | Which user this chunk describes (FK, CASCADE) |
| `source_type` | `'user_profile'` \| `'post'` (v1. More later: comment, event, composite) |
| `source_id` | `posts.id` for a post chunk; NULL for a profile chunk |
| `chunk_index` | Order when one source is split into several chunks (always 0 in v1) |
| `topic` | Topic label (the post's first tag) |
| `content` | The normalized text that was embedded. Kept for debugging/rebuilding |
| `embedding` | `VECTOR(1024)`, mxbai-embed-large, HNSW cosine index |
| `model_name` | The model that produced the embedding (default `mxbai-embed-large`) |

Deduplication uses **two partial unique indexes** (a plain UNIQUE misses rows with
`source_id IS NULL`). Deleting a user deletes their chunks (FK CASCADE).

### The 3 chunk layers by design

1. **User profile chunk**, gathers the fields that describe the user: interests,
   skills, bio, job, company, location (exactly one chunk per user).
2. **Entity chunk**, each post is its own chunk: content + article title + tags.
3. **Composite chunk**, a summary chunk per topic. *Not built in v1.*

### Alias normalization when building chunks

Interests/skills/tags go through the **Tier-1 exact lookup** of `interest_entities`
(plain SQL, no Ollama call): an alias gets its canonical name appended to the text,
`"JS"` → `"JS (JavaScript)"`. Why (measured with mxbai-embed-large):

| Input | Cosine with "Kimetsu no Yaiba" |
|---|---|
| "One Piece" (a different anime!) | 0.634 |
| "Demon Slayer" (official EN name) | 0.531 |
| "KNY" | 0.526 |
| "sửa xe máy" (noise floor) | 0.475 |
| "Thanh gươm diệt quỷ" (VN name) | 0.474 |

→ The embedding model **cannot** resolve abbreviations or Vietnamese names on its
own; the alias table is the exact identity layer, and embeddings handle the fuzzy
semantics.

---

## 3. Chunk build flow (incremental. No more full-rebuild cron)

**Files:** `server/Sources/App/AI/ChunkService.swift`, `Jobs/BackgroundJobs.swift`
(`ChunkEmbedJob`, `ChunkSweepJob`)

```
Create post ──► tag queue (Vapor Queues) ──► tags done ──► enqueuePostEmbed ──► buildPostChunk
Link-only post (no content) ──────────────────► enqueuePostEmbed (embed directly)
Edit post (PATCH) ────────────────────────────► enqueuePostEmbed (re-embed)
Delete post (soft delete) ────────────────────► deletePostChunks (chunk disappears immediately)

Onboarding done (POST /auth/setup) ───────────► enqueueProfileEmbed ──► buildProfileChunk
Edit profile (PATCH /users/me) ───────────────► enqueueProfileEmbed
```

- The Vapor Queues job `ChunkEmbedJob` (Redis) has two kinds, `post` / `profile`, and is
  dispatched with up to 3 retries. `OllamaGate` keeps background embedding from
  starving user-facing searches.
- **There is no status column**: "pending" is inferred, a post/user with no
  matching chunk needs embedding.
- **`ChunkSweepJob`** (runs at boot and then every 30 minutes; it also re-embeds stale chunks):
  1. `'posted'` posts missing a chunk → enqueue (this is also the backfill mechanism).
  2. Users missing a profile chunk → enqueue.
  3. Orphaned chunks (post deleted/hidden) → delete.

### English normalization when building chunks

Vietnamese free text (post content + article title, and the profile bio) is
**translated to English** (`aiService.translateToEnglish`, qwen2.5) before embedding;
the chunk's `content` stores the translated version. Interests/skills/tags are left
as they are because they already went through canonicalization (mostly proper nouns
or English).

Why, measured: a Vietnamese query (normalized to EN) compared against a post about
"leo núi, cắm trại" (hiking, camping):

| Chunk side | Cosine with EN query "hiking and camping" |
|---|---|
| **EN (translated)** | **0.775**. Above the 0.6 threshold, surfaces |
| VN (untranslated, old) | 0.392. Below the threshold, **never matches** |

→ Translating only the query side and not the chunk side leaves the two sides
misaligned, matching worse than leaving both in Vietnamese.

---

## 4. The search flow in detail

### Step 1, iOS calls the API

```
POST /api/search/ai   (JWT, the searcher is the user in the token)
Body: { "query": "tìm bạn thích anime để hẹn hò", "mode": "friend", "radiusKm": 10 }
```

### Step 2, Query Understanding (`OllamaService` → `extractSearchCriteria`)

The LLM `qwen2.5:7b-instruct-q4_k_m` via Ollama, in **2 rounds** (it used to be 3):

**Stage 1, Normalizer** (1 call that combines translation, noise removal and classification):
- `intent_en`, the core intent translated to English, proper nouns kept as-is
- `mode` (friend/colleague), `has_entity` (whether a specific proper name is mentioned)
- `target_gender`, set only when the user **says so explicitly** ("bạn nam/nữ"), never guessed

**Stage 2, Extractor** (2 parallel calls, run on `intent_en`):
- **Entity Extractor** (runs only when `has_entity`) → `entity_name`, `entity_type`,
  `entity_keywords`
- **Semantic Extractor** → `interest_groups`, `skills`, `bio_keywords`,
  `job_title_keywords`, `location`, `place_name` (the prompt varies by mode)

Step 1.5 follows: geocode the venue → `searchCoords` (non-fatal). The LLM only parses. It does no ranking.

### Step 3, Query Builder (`SearchController`, plain code, no LLM)

**The searcher's own vector is not blended in.** The query vector comes straight
from the search content, built by two functions that run in parallel:

`buildEntityVector`, turns a specific entity into one vector via 3 branches:

| Branch | Condition | Action |
|---|---|---|
| 1 | Exact match in `interest_entities` (canonical/aliases) | embed the **canonical_name** |
| 2 | Vector match ≥ 0.8 (confident) | embed the canonical + auto-save the alias (in the background) |
| 3a | Gray zone 0.6–0.8 | embed the entity **directly** + return `entity_suggestions` to ask the user |
| 3b | < 0.6 (new proper noun) | embed directly + fire-and-forget Wikipedia self-learning |

`buildGeneralVector`, embeds `interests + skills` (general semantics).

The two vectors run two retrieval passes in parallel, then are **weighted-merged by user id**:
`score = 0.7 × entity_score + 0.3 × general_score` (a missing side counts as 0),
entity is preferred but general is not excluded. The constants `W_ENTITY`/`W_GENERAL`
are at the top of the file. When the criteria produce no vector, fall back to embedding
`intent_en` (not the raw prompt).

### Step 4, Chunk retrieval (`SearchStore` → vectorSearch)

A single SQL statement with 4 CTE layers:

```
① chunk_pool : the 200 nearest chunks (ORDER BY embedding <=> $vec, HNSW)
② hits       : keep similarity ≥ 0.6 (chunk-level threshold)
③ user_scores: group by user_id
               retrieval_score = 0.7 × max(sim) + 0.3 × (Σ top-3 sim ÷ 3)
④ personal   : personalized rerank
               score = 0.85 × retrieval + 0.15 × sim(searcher's profile chunk,
                                                     candidate's profile chunk)
               (if either side lacks a profile chunk → use plain retrieval)
```

Formula ③: the best chunk decides 70%, plus 30% for "diligence", divided by a
fixed 3, so only a user who matches in several sources (profile + multiple posts)
gets the full amount. The weights are constants at the top of `SearchStore`
(`W_MAX`, `W_AVG`, `W_RETRIEVAL`, `W_PERSONAL`, `CHUNK_POOL_SIZE`). Easy to tune.

**Hard filters** are applied at the user level (after grouping, before LIMIT 20):

| Filter | Condition |
|---|---|
| `mode` | `u.default_mode = 'friend'` or `'colleague'` |
| `location` | `u.location ILIKE '%...%'` |
| `target_gender` | `u.gender = <gender the user stated>`, **wins** over the dating heuristic |
| `partner words` | dating words ("to date", "người yêu"…) are dropped from the query; the rest (gender, location, interests) is still searched. There is no longer a reverse-gender filter. |
| `radius` | Haversine over `vn_wards` when searchCoords + radiusKm are present |
| `interest_groups` | AND across groups, OR within a group (two-way substring) |
| `block / self` | exclude users who blocked each other (both directions) and exclude the searcher |

### Step 5, Result returned to iOS

```json
{
  "data": [...], "criteria": {...}, "reasoning": "...", "tips": "...",
  "entity_suggestions": [
    { "keyword": "...", "candidates": [{ "entity_id": "...", "canonical_name": "..." }] }
  ]
}
```

`entity_suggestions` (usually empty) is present only when an entity falls in the
0.6–0.8 gray zone, see the alias-confirmation section below.

### Step 6, The human-confirmed alias learning loop

Auto-saving aliases (like the old Tier-2, threshold 0.65) has a trap: for
"thanh gươm diệt quỷ", **One Piece (0.634) scores higher than Demon Slayer (0.531)**,
so a WRONG alias could be saved with confidence. So we split by confidence:

- **≥ 0.8**, confident → auto-save the alias (keeps the automation).
- **0.6–0.8**, gray zone → **do not** auto-save; return `entity_suggestions`, and iOS
  shows the chip *"For 'X', did you mean? [Google +]"* **right after the AI keyword
  badges, before the result list** (it does not block the search. Results still
  render below). When the user taps it → `POST /api/entities/alias {keyword, entity_id}`
  → the alias is saved → next time Tier-1 catches it immediately.
- **< 0.6**, ignored (it is embedded directly anyway).

**Files:** `AI/EntityLookupService.swift` (`lookupEntity`, `saveAlias`, thresholds in
`SearchStore.swift`), `SearchController.entityAlias`,
iOS `SearchView.entitySuggestionsBox` + `SearchViewModel.confirmAlias`.

---

## 5. Recommendation feed (`Stores/FeedStore.swift`)

It also reads from `user_embedding_chunks`. A single source:

```
taste vector = the viewer's profile chunk
compare cosine with each post's chunk (source_type='post', 1 post = 1 chunk)
threshold 0.65 → keyset pagination (score DESC, id DESC)
```

A viewer with no profile chunk (onboarding not finished) gets an empty feed, and the
client falls back to the regular feed. Privacy/block/mode/community filters are the
same as the post list.

---

## 6. File → responsibility map

### Backend (`server/Sources/App/`)

```
AI/ChunkService.swift             ← Build/delete chunks (profile+post), EN translation + alias canonicalization
AI/OllamaService.swift            ← Normalizer + Extractor + embedText + translateToEnglish
AI/OllamaGate.swift               ← Priority gate: user searches before background embedding
AI/EntityLookupService.swift      ← Entity lookup (exact, vector, Wikipedia tier), saveAlias
AI/WikipediaService.swift         ← Wikipedia lookup for proper nouns
AI/VenueLocationService.swift     ← Venue/place → province + coords
AI/PostTagExtractService.swift    ← Tag extraction; when done, chains the post embed
AI/SearchStore.swift              ← chunk-based vector search + score + rerank + hard filters
AI/SearchRanking.swift, PostRanking.swift, SearchConcepts.swift ← ranking nudges, concept catalogue
Jobs/BackgroundJobs.swift         ← ChunkEmbedJob, TagExtractionJob, 30-minute ChunkSweepJob
Controllers/SearchController.swift ← Orchestration: criteria → Query Builder (3 branches) → merge → suggestions;
                                     POST /api/search/ai, /ai/posts, POST /api/entities/alias
Stores/FeedStore.swift            ← Feed from chunks (taste vector = profile chunk)
```

### iOS

```
Features/Search/Views/SearchView.swift           ← UI: banner, results, "did you mean…?" chip (entitySuggestionsBox)
Features/Search/ViewModels/SearchViewModel.swift ← State + API call + confirmAlias
Features/Search/Repository/UserRepository.swift  ← aiSearch + confirmAlias
Core/Network/DTOs/AISearchResponseDTO.swift      ← Decodes the response + EntitySuggestionDTO/EntityCandidateDTO
Core/Network/Endpoint.swift                      ← Defines the .aiSearch endpoint
```

---

## 7. Technology & models

| Component | Technology |
|---|---|
| iOS frontend | SwiftUI, `@Observable` macro (deployment target iOS 18), `async/await` |
| Backend | Swift 5.10, Vapor 4 (runs on the host via `./dev.sh start`) |
| Database | PostgreSQL 16 + `pgvector` (HNSW), baseline schema `001_init.sql` |
| LLM runtime | Ollama (local) |
| LLM model | `qwen2.5:7b-instruct-q4_k_m`, normalize/translate/parse criteria + translate chunks |
| Embed model | `mxbai-embed-large` (1024 dimensions). Chunks, queries, entity lookup |
| Queue | Vapor Queues + Redis (tag extraction, chunk embedding, translation) |
| Logging | Vapor `Logger` |
| Scheduled jobs | Vapor Queues schedules (chunk sweep every 30 minutes; see `Jobs/BackgroundJobs.swift`) |

---

## 8. Notable points / limitations

**Gains over the old design:**

- New users **no longer wait until 3 a.m.**: the profile chunk is built as soon as
  onboarding finishes; a post is embedded right after its tags are extracted.
- Results are explainable: you can see which chunk made a user match (`content` is stored).
- Search stays close to the prompt (not diluted by the searcher's own profile vector);
  personalization remains, but only as a seasoning at the rerank step (15%).
- One vector source for both search and the feed.
- **Query and chunks share the same English space** → Vietnamese posts/profiles still
  match queries (measured: 0.392 → 0.775).
- Entities resolve to canonical names, plus a human-confirmed alias learning loop → avoids learning wrong aliases.

**Remaining limitations:**

- Ollama down → search returns `[]`, and chunk builds pile up in the retry queue + sweep.
- English translation adds 1 LLM call per chunk (in the background) and 1 LLM round
  per search, acceptable at ~1000 users, not optimized for heavy load.
- Hard thresholds (0.6 chunk / 0.65 feed / 0.8 alias). They don't self-adjust yet.
- Top-200 chunk pool: a user with very many matching posts can crowd out other users.
- Composite chunks (layer 3) and new source_types (comment, event) are not built yet.
- The Normalizer sometimes classifies ambiguously (e.g. "React" as a skill instead of
  an entity), harmless since it still matches through the general branch.
