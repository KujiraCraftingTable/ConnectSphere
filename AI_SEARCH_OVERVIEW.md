# AI Search, How It Works (ConnectSphere)

> A reading guide, not a design document. Every description reflects the current code.
> For a comparison with Spotify / Netflix / Amazon and the upgrade plan, see [`AI_SEARCH_REVIEW.md`](AI_SEARCH_REVIEW.md).
> Updated 2026-07-04: chunk-based retrieval + a new query pipeline
> (Normalizer → Extractor → Query Builder), with English normalization on both sides.
>
> **Updated 2026-11:** search also has a post-only endpoint (`POST /api/search/ai/posts`), a cached criteria step (migration 086),
> logged search sessions/events (079) and a curated interest catalogue (080); the Home feed
> ranks with impressions and feedback (076–077), capped at 400 candidates from the last 60 days.
>
> **Updated 2026-11-15:** people search now picks people, not chunks. Hard filters run first, each
> persona has its own profile chunk (migration 143), each person has up to five interest vectors
> per mode built from what they post and react to (migration 144), and the vector leg scores a
> person by profile and interests together. Measurements behind this: an HNSW recall check (`doc/hnsw-check.md`, kept outside the repository).

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
                      │  WHO MAY APPEAR (plain SQL)              │
                      │  hard filters + topic gate → eligible    │
                      └────────────────────┬────────────────────┘
                                           │
                      ┌────────────────────▼────────────────────┐
                      │  RETRIEVAL (pgvector + full text)        │
                      │  vector leg: query vs each person's      │
                      │    profile chunk + interest vectors →    │
                      │    100 people; their posts = evidence    │
                      │  keyword leg: full text + names          │
                      └────────────────────┬────────────────────┘
                                           │
                      ┌────────────────────▼────────────────────┐
                      │  MERGE + RERANK                          │
                      │  entity+general → RRF with keyword →     │
                      │  taste / social / activity → top 20      │
                      └────────────────────┬────────────────────┘
                                           │
              [iOS App] ← users + evidence + criteria + warnings + entity_suggestions
```

Two core differences from the old design:

1. **There is no single `users.embedding` any more**. Each user has a profile chunk per
   persona and a chunk per post in `user_embedding_chunks`, plus a few interest vectors in
   `user_interest_vectors`. A person is matched on the profile and interest vectors; the
   post chunks explain the match.
2. **Both the query and the chunks are normalized to English** before embedding, because
   `mxbai-embed-large` is weak at Vietnamese. Both sides must meet in the same space.

---

## 2. The `user_embedding_chunks` table

**Schema:** `backend/migrations/001_init.sql`, plus `033` (`source_hash`) and `143` (`mode`)

| Column | Meaning |
|---|---|
| `user_id` | Which user this chunk describes (FK, CASCADE) |
| `source_type` | `'user_profile'` \| `'post'` (v1. More later: comment, event, composite) |
| `source_id` | `posts.id` for a post chunk; NULL for a profile chunk |
| `mode` | `'hobby'` \| `'work'` on a profile chunk (which persona it describes); NULL on a post chunk, whose mode is the post's |
| `chunk_index` | Order when one source is split into several chunks (always 0 in v1) |
| `topic` | Topic label (the post's first tag) |
| `content` | The normalized text that was embedded. Kept for debugging/rebuilding |
| `embedding` | `VECTOR(1024)`, mxbai-embed-large, HNSW cosine index |
| `model_name` | The model that produced the embedding (default `mxbai-embed-large`) |
| `source_hash` | Fingerprint of the text the chunk was built from; a mismatch means it is out of date |
| `search_tsv` | The same text for full-text search (keyword leg) |

Deduplication uses **two partial unique indexes** (a plain UNIQUE misses rows with
`source_id IS NULL`). Deleting a user deletes their chunks (FK CASCADE).

### The 3 chunk layers by design

1. **User profile chunk**, one per persona the user has set up (migration 143), so
   Hobby and Work never mix:
   - `hobby`: interests, Hobby bio, location
   - `work`: skills, Work bio, job title, company, work history, location
2. **Entity chunk**, each post is its own chunk: content + article title + tags + the
   alt text its author wrote for the photos (migration 145). What is *in* a photo or
   video is not read (see `KNOWN_GAPS.md`).
3. **Composite chunk**, a summary chunk per topic. *Not built in v1.*

### The `user_interest_vectors` table (migration 144)

A profile chunk is what someone says about themselves. These rows are what they show:
the embeddings of the public posts they wrote (weight 1.0), commented on or shared (0.9)
or liked (0.8) in the last 180 days, grouped into **at most five interests per mode**
(`FeedStore.clusterTaste`, a weighted k-means on cosine similarity). One averaged vector
would sit between football and cooking and match neither well, so each interest keeps
its own centroid.

| Column | Meaning |
|---|---|
| `user_id`, `mode`, `cluster_index` (0–4) | Primary key |
| `embedding` | `VECTOR(1024)`, the interest's centroid, HNSW cosine index |
| `weight` | Summed weight of the posts in it |
| `post_count` | How many posts are in it |
| `source_hash` | Fingerprint of the posts and weights it was built from (same on every row of a user and mode) |

Building them is arithmetic over post embeddings that already exist: no model call.
Likes are private and are used only here, never shown.

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

Onboarding done (POST /auth/setup) ───────────► enqueueProfileEmbed ──► buildProfileChunk (hobby + work)
Edit profile (PATCH /users/me) ───────────────► enqueueProfileEmbed

Post chunk built ─────────────────────────────► InterestVectorService.refreshAuthor (author's interests)
Like / comment / share, or one undone ────────► next ChunkSweepJob (within 30 minutes)
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
  4. Interest vectors whose signals changed (new or undone posts and reactions, or
     activity older than 180 days) → rebuilt (`InterestVectorService.sweep`).
- A profile is out of date while **either** persona's chunk is
  (`profile_embed_source_hash(user, mode)`, view `embedding_out_of_date`).

### English normalization when building chunks

Vietnamese free text (post content + article title + photo alt text, and the profile bio) is
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
Body: { "query": "tìm bạn thích anime ở Hà Nội", "mode": "hobby", "radiusKm": 10 }
```

Every search is recorded as a search session (used for metrics and `/explain`).

### Step 2, Query Understanding (`OllamaService` → `extractSearchCriteria`)

The LLM `qwen2.5:7b-instruct-q4_k_m` via Ollama only parses; it ranks nothing. Results
are cached for 24 hours.

- `intent_en`, the core intent translated to English, proper nouns kept as-is
- `mode` (hobby/work), `target_gender` and age only when the user **says so explicitly**
- `entity_name`, `entity_type`, `entity_keywords` when a specific proper name is mentioned
- `interest_groups` (Hobby), `skills` / `job_title_keywords` (Work), `bio_keywords`,
  `location`, `place_name`

Each topic becomes a gate a person must pass (`SearchConcepts.concepts`). A job title or
bio word that repeats a topic already named is not one more gate: "developers" next to
"iOS developer" is dropped, and "iOS developer" next to the iOS skill is folded into it
as another way to match. Free terms match in the singular and the plural ("developers"
finds "iOS Developer").

Partner wording ("to date", "người yêu") is dropped and the rest is searched. A named
venue is geocoded for the radius filter; with no place named the radius is measured from
the searcher's own ward.

### Places in a prompt (`PlaceReader`)

`vn_wards` holds the units in force since 1 July 2025: 3,321 wards in 34 provinces, no
districts. People still write the old names, so `vn_ward_former_names` (migration 146,
10,602 rows) maps every former ward, with its district and province, to today's ward(s).

Two phrases are tried, in this order: what follows "ở / tại / gần" in the prompt as typed,
then `place_name` from Step 2. The typed one comes first because the LLM respells places
("thu đuc", "45 Le Stung") or leaves them out. Each is read in three tiers:

1. **Names, locally.** Ward, former ward, former district and province names count on
   their own, accented or not ("binh thanh", "ben nghe q1"). A name that is both a former
   district and a ward means the district ("bình thạnh" → the five wards formed from Quận
   Bình Thạnh). A name found in several provinces needs the province in the phrase;
   failing that, the searcher's own province decides, and failing that it is skipped. A
   province in the phrase is a hard filter.
2. **Addresses and venues, by geocoder.** A phrase with a house number or "đường"
   ("45 Lê Thánh Tôn") goes to Nominatim, which returns the ward it is in
   (`suburb: "Phường Sài Gòn"`). Only the address is sent, cut at chatter ("nhé",
   "thích …"), with the province the phrase names, or else the searcher's own, appended:
   "12 Nguyễn Trãi" exists in many cities. An answer outside that province is refused.
3. **Nearest ward.** When Nominatim's ward name isn't one of ours, the ward whose centre
   is nearest its coordinates (within 10 km) is used.

A venue or landmark is first looked up in the checked aliases of `location_aliases`
(migration 149: "Landmark 81", which Nominatim doesn't know by that name), whose
coordinates pick the nearest ward. Nominatim matches loosely, so for a venue an answer
whose name drops a number of the name asked for is refused: "landmark 81" came back as
"PetroVietnam Landmark", in another ward (`VenueLocationService.namesTheSame`).

When people match the rest of the prompt but none is near the place, the response carries
the warning `no_match_near` with the place as it was understood, in the gazetteer's
spelling ("Quận Bình Thạnh", "Phường Bến Nghé, Quận 1"), so a typed "binh thanh" is shown
back correctly.

The prompt as a whole is also read with the strict rule (a ward or district needs its
kind in front: "quận 5", "P.12"), since everyday words are ward names too
("Thành Công", "Bình Minh").

### Step 3, Query Builder (`SearchController`, plain code, no LLM)

**The whole prompt is never embedded**: "find a friend who likes …" reads close to every
profile. The query vectors come from the criteria, built in parallel:

`buildEntityVector`, turns a specific entity into one vector via 3 branches:

| Branch | Condition | Action |
|---|---|---|
| 1 | Exact match in `interest_entities` (canonical/aliases) | embed the **canonical_name** |
| 2 | Vector match ≥ 0.8 (confident) | embed the canonical + auto-save the alias (in the background) |
| 3a | Gray zone 0.6–0.8 | embed the entity **directly** + return `entity_suggestions` to ask the user |
| 3b | < 0.6 (new proper noun) | embed directly + fire-and-forget Wikipedia self-learning |

`buildGeneralVector`, embeds `interests + skills` (general semantics).

`conceptVectors`, embeds each topic of the prompt on its own, for the topic gate.
A topic the LLM left in Vietnamese is translated to English first (`englishConcepts`):
stored text and vectors are English, and "chó" embedded as typed sat nearer unrelated
posts (0.64–0.66) than posts about dogs (0.48–0.50).

"Like me" and "More like @x" add vectors of their own: the searcher's taste vectors, or
that person's profile chunk for the search's mode.

### Step 4, Who may appear (`SearchStore`)

Two things decide who can be a result, **before** any similarity is computed:

**Topic gate** (`conceptPeople`): each interest group, skill set or entity is a topic. A
person passes a topic if they picked it as an interest or skill, wrote its words in their
profile or a public post, or posted about it in this mode. Only people who pass **every**
topic are allowed.

**Hard filters** (`eligible`, the first CTE of `vectorSearch`):

| Filter | Condition |
|---|---|
| `persona` | has set up the search's mode (`hobby_display_name` / `work_display_name`) |
| `location` | `u.location` contains the place, when there is no radius |
| `named wards` | The prompt names a ward, district or address (see "Places in a prompt" below). With a radius: people whose ward centre is within it of any of those wards' centres. With none: only people who live in those wards. Takes over from `location` and the centre of the `radius` row |
| `radius` | The app setting `radiusKm` ∈ {5,10,15,20,25,30} (else 400; absent = unlimited) is the **most** a search may reach. A distance in the prompt ("trong vòng 3 km", "within 10 km"; `SearchConcepts.distanceKm`, 1–50 km) is used, but never beyond that setting; with no distance in the prompt the setting itself is the radius. The distance is taken out of the prompt before the place is read. Straight-line (haversine) km from the centre to each person's ward centre (`users.ward_id`, required at sign-up). Centre: the place the prompt names, else the searcher's own ward. Each result carries `distance_km`, rounded up to 5 km |
| `target_gender`, age | only when the prompt states them |
| `block / ban / self` | not deleted, not banned, not blocked either way, not the searcher |
| `connections` | people already connected in this mode are left out |
| `topic gate` | the allowed people from above, when the prompt names topics |

They used to run after the nearest 200 chunks were picked, so people who could not be
shown filled the pool (79 of 200 slots in a test with a gender filter).

Interest groups also lift the score (`+0.1 ×` the share of groups matched); that part
ranks and removes nobody.

### Step 5, Retrieval (`SearchStore.vectorSearch`)

Each query vector runs one `vectorSearch`; the keyword leg runs one more.

**Vector leg** (`personHits`), a person at a time:

```
① near_profile / near_interest : the eligible people whose profile chunk (mode's
                                 persona) or interest vectors are nearest the query
② person_sims : declared = similarity to the profile chunk
                shown    = similarity to their closest interest vector
③ people      : keep those with declared or shown ≥ threshold (0.6; 0 inside the gate)
                score = max(shown, 0.9 × declared) + 0.3 × min(shown, declared)
                best 100 people
④ evidence    : those people's own chunks and the posts they reacted to
                (like × 0.8, comment / share × 0.9), up to 10 per person; each
                person keeps their closest one even below the threshold
```

What someone shows counts slightly more than what they say, and the two agreeing counts
most: profile and behaviour both matching > behaviour only > profile only. Someone with
no matching activity is not penalised, they just get no agreement bonus.

The query runs with `SET LOCAL hnsw.iterative_scan = strict_order` (pgvector ≥ 0.8). An
HNSW scan yields only `hnsw.ef_search` (40) candidates and filters run after it, so
without this the pools in ① would shrink to ~40 or fewer once the planner uses the index.

**Keyword leg**: full text over chunk text (`search_tsv`) for the criteria terms, still
pooled by chunk (200), plus name matching against the prompt ("Lý Thảo" → @lythao).

### Step 6, Merge and rerank (`SearchController`, `SearchRanking`)

1. Entity and general lists merge by score: `0.7 × entity + 0.3 × general` (a missing
   side counts as 0). Personal vectors: each person keeps their best.
2. Reciprocal rank fusion (k = 60) over four rankings: semantic, text, names (weight 2),
   personal. Ranks, not scores, because cosine and text rank are on different scales.
3. Rerank for the searcher: `0.65 × retrieval + 0.20 × taste + 0.10 × social + 0.05 × activity`;
   someone marked "Not a fit" sinks for 30 days.
4. Spread so one city doesn't fill the page, then the top **20**.

Fallbacks: a prompt with only filters ("bạn nữ ở Hà Nội") returns everyone who passes
them, nearest the searcher's taste first; only a name returns the name hits; nothing
usable returns the `query_unclear` warning.

### Step 7, Result returned to iOS

```json
{
  "data": [...], "criteria": {...}, "warnings": [...], "search_session_id": "...",
  "entity_suggestions": [
    { "keyword": "...", "candidates": [{ "entity_id": "...", "canonical_name": "..." }] }
  ]
}
```

Each person carries `match_evidence`: the matching profile text, their matching posts
grouped by topic, and public comments / shares on matching posts. Likes are never shown.
`entity_suggestions` (usually empty) is present only when an entity falls in the
0.6–0.8 gray zone, see the alias-confirmation section below.

### Searching posts (`POST /api/search/ai/posts`, `aiPostSearch`)

Post search follows the same steps as people search, with its own Step 2: people are
described by interests, skills and titles, but a post can be about anything, so the LLM
(`OllamaService.extractPostQuery`, its own prompt, cached like the people criteria) breaks
the prompt into post elements:

- `topics`: one group per thing the posts should be about, an English phrase and its
  synonyms: "hoàng hôn trên biển" → `[["sunset over the sea","sunset at the beach"]]`,
  "bài viết về chó và bóng đá" → `[["dog","puppy"],["football","soccer"]]`
- `place`: the place they should be about, as typed

Each topic, and each catalogue name found in the prompt, becomes one vector (Step 3). The
prompt as a whole is never embedded. Then:

1. For each topic, `SearchStore.conceptPosts` returns the posts about it: the topic's
   English words are in the post's chunk text, or the chunk is close enough to the topic
   vector: 0.64 (`conceptPostMin`) for a word or two, 0.60 (`phrasePostMin`) for a phrase
   of three or more words, which sits lower (posts that fit measured 0.60–0.72, the
   closest post to a phrase nothing fits 0.50–0.55).
2. The place the prompt names (the typed phrase after "ở / tại / gần", then the LLM's
   `place`) is read as today's wards by `PlaceReader`, exactly as in people search, and
   `SearchStore.postsInPlace` returns the posts about one of those wards (or, when only a
   province is named, about that province).
3. A post about **at least one** topic is kept (`SearchConcepts.postMatches`). The place
   then counts as one more criterion met; it is never a reason on its own, except when
   the prompt has a place and no topic. Requiring every topic hid good posts whenever
   the LLM named a topic nobody had written about.
4. `PostStore.findVisible` applies the feed's visibility rules.
5. Order (`PostRanking`): posts meeting more of the prompt's criteria first; among
   equals the most popular first (likes + shares + comments, counted alike); closeness
   to the topics only breaks ties. The searcher's taste and what they have seen play no
   part, so a prompt gives everyone the same order. Top 20. `match_scores` is the average
   closeness to the topics a post is about.

Only text is searched: caption, article title, tags, job details and photo alt text.

#### The places a post is about (`PostPlaceService`, migration 147)

A post has no place field, and a vector is poor at place names ("Bình Thạnh" is not near
"Lê Thánh Tôn"). So when a post is embedded, in the background:

1. If its text holds no ward, district or province name and no number, it names no place.
2. Otherwise the LLM lists the place phrases in it (`OllamaService.extractPlaces`):
   most ward names are everyday words ("Thành Công", "Bình Minh"), so the LLM decides
   which words are places.
3. `PlaceReader` reads each phrase (names locally, street addresses through Nominatim).
   It is stricter here than for a prompt, because people write about places far from
   home: a ward named on its own must be in the province the post names, else in the
   author's own (a former district stands on its own); a venue or landmark ("Hồ Tây")
   is only looked up when the post names its province.
4. The wards are stored in `posts.place_ward_ids`, their provinces and any province named
   on its own in `posts.place_province_codes`. Nobody is shown them.

`place_ward_ids` is NULL until a post has been read, and such a post counts as out of
date, so the sweep reads existing posts and retries a failed read. Editing a post reads
its places again.

### The human-confirmed alias learning loop

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

The home feed ranks posts with one blended score. It reads the same post chunks as
search, so it knows a post by its words only (caption, title, tags, alt text).

### Candidates

The newest 400 posts of the last 60 days in the feed's mode, plus posts by the viewer's
connections, by people and sellers they follow, and ones their peers engaged with. The
post list's visibility rules apply (privacy, blocks, communities, hidden, muted words).

### The viewer's taste (`buildTasteVectors`)

Several vectors, so separate interests don't blur into one average. A post is scored by
the one it matches best.

- The profile chunk of the feed's mode.
- Up to 4 clusters of what the viewer did in the last 60 days (at most 200 posts), each
  action weighted and halved every 14 days:

  | Action | Weight |
  |---|---|
  | Share | 3 |
  | Comment, save, "Show more like this" | 2 |
  | Read for 8 s or more | 1.5 |
  | Like, open | 1 |
  | Scrolled past in under a second | −0.5 |
  | "Not interested" | −1.5 |

  The negative ones pull every cluster away from what was skipped.
- A brand-new account, with neither, starts from what it picked at sign-up: interests
  for Hobby, skills for Work.

**All of it is per mode.** Only posts of the feed's mode count as behaviour, so what
someone likes in Hobby does not shape their Work feed.

### Score

| Term | Weight | What it is |
|---|---|---|
| Semantic | 0.50 | cosine to the best-matching taste vector |
| Recency | 0.35 | decays with a 72 h time constant |
| Engagement | 0.15 | likes, comments and shares **per viewer**, not lifetime totals |
| Closeness to the author | up to +0.25 | connection, follow, and how much the viewer liked, commented on, read and messaged them in 60 days |
| New author | +0.05 | someone the viewer has never met, for exploration |
| Peers | up to +0.15 | the 50 people who engaged with the same posts in 30 days engaged with this one |
| Already seen | −0.5 / −0.2 | first seen in the last 72 h, or earlier |
| Feedback | −0.4 … +0.2 | like, or by the author of, a post given "Not interested" / "Show more" in 30 days |
| Cold start only | +0.1 / +0.05 | author in the same province / a language the viewer speaks |

### Two passes

1. **Personalised:** posts by connections or follows, posts with semantic ≥ 0.65, or
   ones enough peers engaged with. Posts seen in the last three days and ones given
   "Not interested" are left out.
2. **Relaxed:** when that doesn't fill a page, everything else, by the same score.

Paging is keyset (score, id), with "now" pinned at the first page so scores don't drift
between pages.

### Page order (`spread`)

Within a page the same author never shows twice in a row, and in each run of ten no
author has more than two posts or topic more than three. Nothing is dropped.

### Not used yet

The wards a post is about (`posts.place_ward_ids`, migration 147) play no part: the only
place signal is the cold-start "same province as the author". No feed metric is
recorded, so the weights above are hand-set and unmeasured.

---

## 6. File → responsibility map

### Backend (`server/Sources/App/`)

```
AI/ChunkService.swift             ← Build/delete chunks (a profile chunk per persona + post), EN translation + alias canonicalization
AI/InterestVectorService.swift    ← Interest vectors per user and mode from posts written / reacted to (migration 144)
AI/OllamaService.swift            ← Normalizer + Extractor + embedText + translateToEnglish
AI/OllamaGate.swift               ← Priority gate: user searches before background embedding
AI/EntityLookupService.swift      ← Entity lookup (exact, vector, Wikipedia tier), saveAlias
AI/WikipediaService.swift         ← Wikipedia lookup for proper nouns
AI/VenueLocationService.swift     ← Venue/place → province + coords (+ the ward Nominatim names)
AI/PlaceReader.swift              ← Ward / district / province names in text → today's wards (former names: migration 146)
AI/PostPlaceService.swift         ← The wards a post is about, read when it is embedded (migration 147)
AI/PostRanking.swift              ← Post search order: criteria met, then popularity
AI/PostTagExtractService.swift    ← Tag extraction; when done, chains the post embed
AI/SearchStore.swift              ← hard filters, topic gate, person-level vector leg (`personHits`), keyword leg, evidence
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
  personalization remains, but only at the rerank step (taste 20%, social 10%, activity 5%).
- One vector source for both search and the feed.
- **Query and chunks share the same English space** → Vietnamese posts/profiles still
  match queries (measured: 0.392 → 0.775).
- Entities resolve to canonical names, plus a human-confirmed alias learning loop → avoids learning wrong aliases.

**Where the time goes** (measured 2026-11-15 on the dev Mac, 9 prompts each, 3 runs, 99
profiles and 265 posts; each search logs one `ai search timing …` line, `Infra/StepTimer`):

| Step | People search | Post search |
|---|---|---|
| LLM reads the prompt | 2,406 ms | 1,278 ms |
| Topic vectors | 87 ms | 44 ms |
| Database (keyword + retrieval) | 41 ms | 24 ms |
| Ranking | 8 ms | 16 ms |
| **Total, first time a prompt is searched** (median) | **2,575 ms** | **1,459 ms** |
| **Total, same prompt again within 24 h** (median) | **164 ms** | **178 ms** |

The LLM is 88–93% of a first search. The first search after the model has been idle adds
its load time (7.4 s measured). A street address adds one Nominatim call (1.3 s measured),
kept in memory afterwards. The repeat figure relies on `search_criteria_cache`; its lookup
compared against `make_interval(hours => bigint)`, which Postgres does not have, so until
2026-11-15 the cache was never read and every search called the LLM.

**Remaining limitations:**

- Ollama down → search returns `[]`, and chunk builds pile up in the retry queue + sweep.
- English translation adds 1 LLM call per chunk (in the background) and 1 LLM round
  per search, acceptable at ~1000 users, not optimized for heavy load.
- Hard thresholds (0.6 chunk / 0.65 feed / 0.8 alias). They don't self-adjust yet.
- The number of interest vectors follows how much someone does, not how many topics they
  have: 15 or more signals always give five clusters, and some come out near-duplicates.
- A single like can form an interest; `weight` is stored but not yet used in the score.
- The 0.6 threshold was set for single chunks. A centroid sits closer to everything, so it
  may be lenient for interest vectors (only matters outside the topic gate, e.g. "like me").
- Someone whose only match is one stray post, with neither profile nor an interest close,
  is no longer found by the vector leg.
- The keyword leg still pools 200 chunks, so a prolific poster can crowd it.
- Composite chunks (layer 3) and new source_types (comment, event) are not built yet.
- The Normalizer sometimes classifies ambiguously (e.g. "React" as a skill instead of
  an entity), harmless since it still matches through the general branch.
