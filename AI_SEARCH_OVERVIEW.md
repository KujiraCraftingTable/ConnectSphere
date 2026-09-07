# AI Search — Cách hoạt động (ConnectSphere)

> Tài liệu đọc hiểu, không phải thiết kế. Mọi mô tả đều phản ánh code hiện tại.
> Cập nhật 2026-07-04: chunk-based retrieval + query pipeline mới
> (Normalizer → Extractor → Query Builder), chuẩn hóa tiếng Anh cả hai phía.

---

## 1. Tổng quan kiến trúc

```
[iOS App]  →  POST /api/search/ai  →  [Backend]
                                           │
                      ┌────────────────────▼────────────────────┐
                      │  QUERY UNDERSTANDING (LLM — qwen2.5)      │
                      │  Stage 1 · Normalizer (1 call)           │
                      │    dịch EN + khử noise + mode +           │
                      │    has_entity + target_gender            │
                      │  Stage 2 · Extractor (2 call song song)  │
                      │    Entity Extractor | Semantic Extractor │
                      └────────────────────┬────────────────────┘
                                           │ criteria
                      ┌────────────────────▼────────────────────┐
                      │  QUERY BUILDER (code thuần — 3 nhánh)    │
                      │  entity → canonical / direct;            │
                      │  general → interests+skills              │
                      │  → entityVec + generalVec (song song)    │
                      └────────────────────┬────────────────────┘
                                           │
                      ┌────────────────────▼────────────────────┐
                      │  CHUNK RETRIEVAL (pgvector HNSW)         │
                      │  top-k chunk → group theo user →         │
                      │  score → rerank → weighted-merge         │
                      └────────────────────┬────────────────────┘
                                           │
              [iOS App] ← users + criteria + reasoning + entity_suggestions
```

Hai khác biệt cốt lõi so với thiết kế cũ:

1. **Không còn `users.embedding` duy nhất** — mỗi user là **nhiều chunk** trong
   `user_embedding_chunks`, điểm tổng hợp từ các chunk trúng.
2. **Cả query lẫn chunk đều được chuẩn hóa sang tiếng Anh** trước khi embed, vì
   `mxbai-embed-large` yếu tiếng Việt — hai vế phải gặp nhau trong cùng không gian.

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

### Chuẩn hóa tiếng Anh khi build chunk

Free-text tiếng Việt (post content + article title, và bio của profile) được
**dịch sang tiếng Anh** (`aiService.translateToEnglish`, qwen2.5) trước khi embed;
`content` của chunk lưu bản đã dịch. Interests/skills/tags giữ nguyên vì đã đi
qua canonicalization (đa số là tên riêng/tiếng Anh).

Lý do — đo thật: query tiếng Việt (đã normalize sang EN) so với post "leo núi,
cắm trại":

| Phía chunk | Cosine với query EN "hiking and camping" |
|---|---|
| **EN (đã dịch)** | **0.775** — vượt ngưỡng 0.6, nổi lên |
| VN (chưa dịch, cũ) | 0.392 — dưới ngưỡng, **không bao giờ khớp** |

→ Nếu chỉ dịch phía query mà không dịch phía chunk thì hai vế lệch nhau, khớp
tệ hơn cả khi cùng để tiếng Việt.

---

## 4. Luồng search chi tiết

### Bước 1 — iOS gọi API

```
POST /api/search/ai   (JWT — người tìm là user trong token)
Body: { "query": "tìm bạn thích anime để hẹn hò", "mode": "friend", "radiusKm": 10 }
```

### Bước 2 — Query Understanding (aiService.js → `extractSearchCriteria`)

LLM `qwen2.5:7b-instruct-q4_k_m` qua Ollama, **2 vòng** (trước là 3):

**Stage 1 — Normalizer** (1 call, gộp dịch + khử noise + phân loại):
- `intent_en` — intent cốt lõi đã dịch sang tiếng Anh, giữ nguyên proper noun
- `mode` (friend/colleague), `has_entity` (có nhắc tên riêng cụ thể không)
- `target_gender` — chỉ set khi user **nói rõ** "bạn nam/nữ", không đoán

**Stage 2 — Extractor** (2 call song song, chạy trên `intent_en`):
- **Entity Extractor** (chỉ chạy khi `has_entity`) → `entity_name`, `entity_type`,
  `entity_keywords`
- **Semantic Extractor** → `interest_groups`, `skills`, `bio_keywords`,
  `job_title_keywords`, `location`, `place_name` (prompt đổi theo mode)

Kèm bước 1.5 geocode venue → `searchCoords` (non-fatal). LLM chỉ parse — không ranking.

### Bước 3 — Query Builder (searchController.js — code thuần, không LLM)

**Không blend vector người tìm.** Query vector đến thẳng từ nội dung tìm kiếm,
xây bằng 2 hàm chạy song song:

`buildEntityVector` — biến specific entity thành 1 vector theo 3 nhánh:

| Nhánh | Điều kiện | Hành động |
|---|---|---|
| 1 | Exact match trong `interest_entities` (canonical/aliases) | embed **canonical_name** |
| 2 | Vector match ≥ 0.8 (tự tin) | embed canonical + auto-save alias (nền) |
| 3a | Vùng xám 0.6–0.8 | embed **thẳng** entity + trả `entity_suggestions` để hỏi user |
| 3b | < 0.6 (proper noun mới) | embed thẳng + fire-and-forget Wikipedia tự học |

`buildGeneralVector` — embed `interests + skills` (ngữ nghĩa chung).

Hai vector chạy 2 lượt retrieval song song rồi **weighted-merge theo user id**:
`score = 0.7 × entity_score + 0.3 × general_score` (thiếu vế nào = 0) — ưu tiên
entity nhưng không loại general. Hằng số `W_ENTITY`/`W_GENERAL` đầu file.
Khi criteria không ra vector nào → fallback embed `intent_en` (không phải raw prompt).

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
| `target_gender` | `u.gender = <giới user nói rõ>` — **thắng** heuristic hẹn hò |
| `dating intent` | fallback: `u.gender = <ngược giới người tìm>` khi bio_keywords có từ hẹn hò (chỉ khi không có target_gender) |
| `radius` | Haversine qua `vn_wards` khi có searchCoords + radiusKm |
| `interest_groups` | AND giữa các nhóm, OR trong nhóm (substring 2 chiều) |
| `block / self` | loại user chặn nhau 2 chiều + loại chính mình |

### Bước 5 — Kết quả trả về iOS

```json
{
  "data": [...], "criteria": {...}, "reasoning": "...", "tips": "...",
  "entity_suggestions": [
    { "keyword": "...", "candidates": [{ "entity_id": "...", "canonical_name": "..." }] }
  ]
}
```

`entity_suggestions` (thường rỗng) chỉ có khi entity rơi vào vùng xám 0.6–0.8 —
xem mục alias confirm bên dưới.

### Bước 6 — Vòng học alias có người xác nhận

Auto-save alias (như Tier-2 cũ, ngưỡng 0.65) có bẫy: với "thanh gươm diệt quỷ",
**One Piece (0.634) điểm cao hơn Demon Slayer (0.531)** → có thể lưu alias SAI một
cách tự tin. Nên chia theo độ tin:

- **≥ 0.8** — tự tin → auto-save alias (giữ tự động hóa).
- **0.6–0.8** — vùng xám → **không** tự lưu; trả `entity_suggestions`, iOS hiện
  chip *"Với 'X', ý bạn là? [Google +]"* **ngay sau AI keyword badges, trước
  danh sách kết quả** (không chặn search — kết quả vẫn render bên dưới).
  User bấm → `POST /api/entities/alias {keyword, entity_id}` → alias được lưu →
  lần sau Tier-1 bắt được ngay.
- **< 0.6** — bỏ qua (đằng nào cũng embed thẳng).

**File:** `entityLookupService.js` (`findEntityCandidates`, `saveAlias`,
ngưỡng `HIGH_CONFIDENCE_THRESHOLD`/`SUGGEST_THRESHOLD`), `routes/entityRoutes.js`,
iOS `SearchView.entitySuggestionsBox` + `SearchViewModel.confirmAlias`.

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
backend/src/services/chunkService.js         ← Build/xóa chunk (profile+post), dịch EN + canonicalize alias
backend/src/services/aiService.js            ← Normalizer + Extractor + embedText + translateToEnglish
backend/src/services/entityLookupService.js  ← Entity lookup: exactMatch, findEntityCandidates, saveAlias
backend/src/services/venueLocationService.js ← Geocode venue/place → tỉnh thành + coords
backend/src/queues/embedQueue.js             ← BullMQ 'chunk-embedding': job post/profile + helpers enqueue
backend/src/queues/tagQueue.js               ← Tag extraction, xong thì chain enqueuePostEmbed
backend/src/jobs/chunkSweepJob.js            ← Sweep mỗi giờ: thiếu → enqueue, mồ côi → xóa (kiêm backfill)
backend/src/controllers/searchController.js  ← Điều phối: criteria → Query Builder (3 nhánh) → merge → suggestions
backend/src/models/searchModel.js            ← vectorSearch() chunk-based + score + rerank + hard filters (target_gender)
backend/src/models/feedModel.js              ← Feed từ chunks (taste vector = profile chunk)
backend/src/routes/searchRoutes.js           ← Route: POST /api/search/ai
backend/src/routes/entityRoutes.js           ← Route: POST /api/entities/alias (confirm alias)
backend/src/config/env.js                    ← Config Ollama URL + model name
```

### iOS

```
Features/Search/Views/SearchView.swift           ← UI: banner, kết quả, chip "ý bạn là…?" (entitySuggestionsBox)
Features/Search/ViewModels/SearchViewModel.swift ← State + gọi API + confirmAlias
Features/Search/Repository/UserRepository.swift  ← aiSearch + confirmAlias
Core/Network/DTOs/AISearchResponseDTO.swift      ← Decode response + EntitySuggestionDTO/EntityCandidateDTO
Core/Network/Endpoint.swift                      ← Định nghĩa endpoint .aiSearch
```

---

## 7. Công nghệ & model

| Thành phần | Công nghệ |
|---|---|
| iOS frontend | SwiftUI, `@Observable` macro (iOS 17+), `async/await` |
| Backend | Node.js 22 (Docker), Express 4 |
| Database | PostgreSQL 16 + `pgvector` (HNSW), schema baseline `001_init.sql` |
| LLM runtime | Ollama (local) |
| LLM model | `qwen2.5:7b-instruct-q4_k_m` — normalize/dịch/parse criteria + dịch chunk |
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
- **Query và chunk cùng không gian tiếng Anh** → bài/hồ sơ tiếng Việt vẫn khớp
  query (đo được: 0.392 → 0.775).
- Entity resolve về canonical + vòng học alias có người xác nhận → tránh học sai.

**Hạn chế còn lại:**

- Ollama down → search trả `[]`, chunk build dồn vào queue retry + sweep.
- Dịch EN thêm 1 LLM call/chunk (chạy nền) và 1 vòng LLM/search — chấp nhận ở
  quy mô ~1000 user, chưa tối ưu cho tải lớn.
- Threshold cứng (0.6 chunk / 0.65 feed / 0.8 alias) — chưa tự điều chỉnh.
- Top-200 chunk pool: user có rất nhiều post khớp có thể lấn chỗ user khác.
- Composite chunk (lớp 3) và các source_type mới (comment, event) chưa làm.
- Normalizer đôi khi phân loại nhập nhằng (vd "React" thành skill thay vì entity)
  — vô hại vì vẫn khớp qua nhánh general.
