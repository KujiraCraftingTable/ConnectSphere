# AI Search — Cách hoạt động (ConnectSphere)

> Tài liệu đọc hiểu, không phải thiết kế. Mọi mô tả đều phản ánh code hiện tại.
> Cập nhật 2026-07-04: chuyển từ 1-user-1-vector sang **chunk-based retrieval**.

---

## 1. Tổng quan kiến trúc

```
[iOS App]  →  POST /api/search/ai  →  [Backend]
                                           │
                                    ┌──────▼──────┐
                                    │  LLM parse  │  extractSearchCriteria()
                                    │  (Ollama)   │  → criteria JSON
                                    └──────┬──────┘
                                           │
                                    ┌──────▼──────┐
                                    │  Embed      │  entity_keywords + interests/skills
                                    │  criteria   │  → 2 query vector (song song)
                                    └──────┬──────┘
                                           │
                                    ┌──────▼──────────────┐
                                    │  Chunk retrieval    │  top-k chunk (HNSW)
                                    │  user_embedding_    │  → group theo user
                                    │  chunks             │  → score → rerank
                                    └──────┬──────────────┘
                                           │
                                    [iOS App] ← users + criteria + reasoning
```

Khác biệt cốt lõi so với thiết kế cũ: **không còn `users.embedding` duy nhất**.
Mỗi user được biểu diễn bằng **nhiều chunk** trong bảng `user_embedding_chunks`,
mỗi chunk mang một ý chính kèm metadata. Điểm của user được **tổng hợp từ các
chunk trúng**, không phải đọc sẵn từ một vector.

---

## 2. Bảng `user_embedding_chunks`

**Schema:** `backend/migrations/001_init.sql`

| Cột | Ý nghĩa |
|---|---|
| `user_id` | Chunk này nói về user nào (FK, CASCADE) |
| `source_type` | `'user_profile'` \| `'post'` (v1 — mở rộng sau: comment, event, composite) |
| `source_id` | `posts.id` với post chunk; NULL với profile chunk |
| `chunk_index` | Thứ tự khi một nguồn tách thành nhiều chunk (v1 luôn 0) |
| `topic` | Nhãn chủ đề (tag đầu tiên của post) |
| `content` | Text chuẩn hóa đã đem đi embed — để debug/rebuild |
| `embedding` | `VECTOR(1024)` — mxbai-embed-large, HNSW cosine index |
| `model_name` | Model đã embed (default `mxbai-embed-large`) |

Dedupe bằng **2 partial unique index** (UNIQUE thường bỏ lọt hàng có
`source_id IS NULL`). Xóa user → chunks tự xóa (FK CASCADE).

### 3 lớp chunk theo thiết kế

1. **User profile chunk** — gom field mô tả user: interests, skills, bio, job,
   company, location (mỗi user đúng 1 chunk).
2. **Entity chunk** — mỗi post là 1 chunk riêng: content + article title + tags.
3. **Composite chunk** — chunk tổng hợp theo chủ đề. *Chưa làm ở v1.*

### Chuẩn hóa alias khi build chunk

Interests/skills/tags được qua **Tier-1 exact lookup** của `interest_entities`
(SQL thuần, không gọi Ollama): alias được nối canonical name vào text —
`"JS"` → `"JS (JavaScript)"`. Lý do (đo thật với mxbai-embed-large):

| Input | Cosine với "Kimetsu no Yaiba" |
|---|---|
| "One Piece" (anime khác!) | 0.634 |
| "Demon Slayer" (tên EN chính thức) | 0.531 |
| "KNY" | 0.526 |
| "sửa xe máy" (noise floor) | 0.475 |
| "Thanh gươm diệt quỷ" (tên VN) | 0.474 |

→ Embedding model **không** tự phân giải được viết tắt/tên tiếng Việt; alias
table là tầng danh tính chính xác, embedding lo phần ngữ nghĩa mờ.

---

## 3. Luồng build chunk (incremental — không còn cron rebuild toàn bộ)

**File:** `backend/src/services/chunkService.js`, `backend/src/queues/embedQueue.js`,
`backend/src/jobs/chunkSweepJob.js`

```
Tạo post ──► tagQueue (BullMQ) ──► tags xong ──► enqueuePostEmbed ──► buildPostChunk
Post chỉ có link (không content) ─────────────► enqueuePostEmbed (embed thẳng)
Sửa post (PATCH) ─────────────────────────────► enqueuePostEmbed (re-embed)
Xóa post (soft-delete) ───────────────────────► deletePostChunks (chunk biến mất ngay)

Onboarding xong (POST /auth/setup) ───────────► enqueueProfileEmbed ──► buildProfileChunk
Sửa hồ sơ (PATCH /users/me) ──────────────────► enqueueProfileEmbed
```

- Queue BullMQ `chunk-embedding` (Redis), 2 loại job `post` / `profile`,
  retry 3 lần exponential backoff, concurrency 1 để không đè Ollama.
- **Không có cột status**: "pending" được suy ra — post/user chưa có chunk
  tương ứng nghĩa là cần embed.
- **`chunkSweepJob`** (chạy ngay lúc boot + mỗi giờ):
  1. Post `'posted'` thiếu chunk → enqueue (đây cũng là cơ chế backfill).
  2. User thiếu profile chunk → enqueue.
  3. Chunk mồ côi (post đã xóa/ẩn) → delete.

---

## 4. Luồng search chi tiết

### Bước 1 — iOS gọi API

```
POST /api/search/ai   (JWT — người tìm là user trong token)
Body: { "query": "tìm bạn thích anime để hẹn hò", "mode": "friend", "radiusKm": 10 }
```

### Bước 2 — LLM parse tiêu chí (searchController.js → aiService.js)

`qwen2.5:7b-instruct-q4_k_m` qua Ollama, chỉ làm nhiệm vụ parse — không ranking.
Output: `interests`, `skills`, `entity_keywords`, `interest_groups`,
`bio_keywords`, `location`, `place_name`, `mode`, `reasoning`, `tips`.
Kèm bước 1.5 geocode venue → `searchCoords` (non-fatal).

### Bước 3 — Embed criteria thành query vector

**Không blend vector người tìm.** Query vector đến thẳng từ nội dung tìm kiếm:

```
entityVec   = embed(entity_keywords)        ← nếu có
interestVec = embed(interests + skills)     ← nếu có
fallbackVec = embed(raw query)              ← khi criteria trống
```

Hai vector chạy 2 lượt retrieval song song rồi **merge theo user id**
(user trúng cả hai được cộng điểm).

### Bước 4 — Chunk retrieval (searchModel.js → vectorSearch)

Một câu SQL 4 tầng CTE:

```
① chunk_pool : top-200 chunk gần nhất (ORDER BY embedding <=> $vec — HNSW)
② hits       : lọc similarity ≥ 0.6 (threshold cấp chunk)
③ user_scores: group theo user_id
               retrieval_score = 0.7 × max(sim) + 0.3 × (Σ top-3 sim ÷ 3)
④ personal   : rerank cá nhân hóa
               score = 0.85 × retrieval + 0.15 × sim(profile chunk người tìm,
                                                     profile chunk ứng viên)
               (thiếu profile chunk ở một trong hai phía → dùng retrieval thuần)
```

Công thức ③: chunk tốt nhất quyết định 70%, cộng 30% "điểm chuyên cần" — chia
cố định cho 3 nên user khớp ở nhiều nguồn (profile + nhiều post) mới ăn trọn.
Các trọng số là hằng số đầu file `searchModel.js` (`W_MAX`, `W_AVG`,
`W_RETRIEVAL`, `W_PERSONAL`, `CHUNK_POOL_SIZE`) — chỉnh dễ.

**Hard filters** áp ở tầng user (sau group, trước LIMIT 20):

| Filter | Điều kiện |
|---|---|
| `mode` | `u.default_mode = 'friend'` hoặc `'colleague'` |
| `location` | `u.location ILIKE '%...%'` |
| `dating intent` | `u.gender = <ngược giới người tìm>` khi bio_keywords có từ hẹn hò |
| `radius` | Haversine qua `vn_wards` khi có searchCoords + radiusKm |
| `interest_groups` | AND giữa các nhóm, OR trong nhóm (substring 2 chiều) |
| `block / self` | loại user chặn nhau 2 chiều + loại chính mình |

### Bước 5 — Kết quả trả về iOS

Shape không đổi so với trước — iOS **không phải sửa gì**:

```json
{ "data": [...], "criteria": {...}, "reasoning": "...", "tips": "..." }
```

---

## 5. Recommendation feed (feedModel.js)

Cũng đọc từ `user_embedding_chunks` — một nguồn duy nhất:

```
taste vector = profile chunk của viewer
so cosine với chunk của từng post (source_type='post', 1 post = 1 chunk)
threshold 0.65 → keyset pagination (score DESC, id DESC)
```

Viewer chưa có profile chunk (chưa onboarding xong) → feed rỗng, client fallback
feed thường. Filter privacy/block/mode/community y như post list.

---

## 6. Map file → chức năng

### Backend

```
backend/src/services/chunkService.js         ← Build/xóa chunk (profile + post), canonicalize alias
backend/src/services/aiService.js            ← LLM parse + embedText (mxbai-embed-large)
backend/src/services/entityLookupService.js  ← Entity lookup 3 tier (exactMatch được chunkService dùng)
backend/src/services/venueLocationService.js ← Geocode venue/place → tỉnh thành + coords
backend/src/queues/embedQueue.js             ← BullMQ 'chunk-embedding': job post/profile + helpers enqueue
backend/src/queues/tagQueue.js               ← Tag extraction, xong thì chain enqueuePostEmbed
backend/src/jobs/chunkSweepJob.js            ← Sweep mỗi giờ: thiếu → enqueue, mồ côi → xóa (kiêm backfill)
backend/src/controllers/searchController.js  ← Điều phối: LLM → embed criteria → vectorSearch → merge
backend/src/models/searchModel.js            ← vectorSearch() chunk-based + score + rerank + hard filters
backend/src/models/feedModel.js              ← Feed từ chunks (taste vector = profile chunk)
backend/src/routes/searchRoutes.js           ← Route: POST /api/search/ai
backend/src/config/env.js                    ← Config Ollama URL + model name
```

### iOS (không đổi trong đợt restructure này)

```
Features/Search/Views/SearchView.swift           ← UI chính: banner, sheet, kết quả
Features/Search/Views/AISearchLoadingView.swift  ← Loading overlay animation
Features/Search/ViewModels/SearchViewModel.swift ← State + gọi API
Core/Network/DTOs/AISearchResponseDTO.swift      ← Decode JSON response
Core/Network/Endpoint.swift                      ← Định nghĩa endpoint .aiSearch
```

---

## 7. Công nghệ & model

| Thành phần | Công nghệ |
|---|---|
| iOS frontend | SwiftUI, `@Observable` macro (iOS 17+), `async/await` |
| Backend | Node.js 20+, Express 4 |
| Database | PostgreSQL 16 + `pgvector` (HNSW), schema baseline `001_init.sql` |
| LLM runtime | Ollama (local) |
| LLM model | `qwen2.5:7b-instruct-q4_k_m` — chỉ parse criteria |
| Embed model | `mxbai-embed-large` (1024 chiều) — chunk, query, entity lookup |
| Queue | BullMQ + Redis (tag extraction, chunk embedding) |
| Logging | `pino` + `pino-pretty` |
| Scheduled jobs | `node-cron` + `setInterval` (chunkSweepJob hourly) |

---

## 8. Điểm đáng chú ý / hạn chế

**Được so với thiết kế cũ:**

- User mới **không phải chờ đến 3h sáng**: profile chunk build ngay khi
  onboarding xong; post embed ngay sau khi tag xong.
- Kết quả giải thích được: biết user trúng vì chunk nào (`content` lưu sẵn).
- Search bám sát prompt (không bị vector profile người tìm pha loãng);
  cá nhân hóa vẫn còn nhưng là gia vị ở bước rerank (15%).
- 1 nguồn vector duy nhất cho cả search lẫn feed.

**Hạn chế còn lại:**

- Ollama down → search trả `[]`, chunk build dồn vào queue retry + sweep.
- Threshold cứng (0.6 chunk / 0.65 feed) — chưa tự điều chỉnh theo mật độ data.
- Top-200 chunk pool: user có rất nhiều post khớp có thể lấn chỗ user khác
  trong pool (chấp nhận được ở quy mô ~1000 user).
- Composite chunk (lớp 3) và các source_type mới (comment, event) chưa làm.
- mxbai-embed-large yếu tiếng Việt — canonicalization đỡ được phần danh tính,
  phần ngữ nghĩa thuần Việt vẫn phụ thuộc model.
