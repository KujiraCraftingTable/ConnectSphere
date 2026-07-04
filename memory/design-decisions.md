# Design Decisions & Discussions

## Interest System (chưa implement)

### Vấn đề
- User nhập interest thủ công → không biết nhập gì
- Database lưu "Anime" quá chung chung → không search cụ thể được
- Normalization: "KNY" = "Demon Slayer" = "Kimetsu no Yaiba" = "thanh gươm diệt quỷ" → cùng 1 entity

### Quyết định: Option C — Category + optional item

```sql
user_interests (user_id, category, entity_id NULL, raw_input NULL)

-- Ví dụ:
(uuid, 'Coffee', NULL, NULL)              -- chỉ category
(uuid, 'Anime',  <kimetsu_id>, 'KNY')    -- có specific item
```

**UI:** Chip picker (popular interests) + optional sub-item + free text input

**Categories có sub-items:** Anime, Movies, Gaming, Music, Books  
**Categories không cần:** Coffee, Travel, Fitness, ...

---

## Entity Resolution (chưa implement)

### Schema
```sql
interest_entities (
  id             UUID,
  canonical_name TEXT,    -- "Kimetsu no Yaiba"
  category       TEXT,    -- "Anime"
  aliases        TEXT[],  -- ["KNY", "Demon Slayer", "thanh gươm diệt quỷ"]
  embedding      VECTOR(768)
)
```

### Flow
1. User gõ "KNY" → LLM normalize → canonical: "Kimetsu no Yaiba"
2. Lưu entity nếu chưa có, hoặc reuse nếu đã có
3. Normalize **async** (background) — không block UX

---

## Personalized Newsfeed (tương lai)

### Mục tiêu
AI phân tích post (caption + ảnh) → nhận ra entity → match với user interest

```
Post: "Tanjiro quá ngầu 🔥"
  → AI extract → entity: "Kimetsu no Yaiba"
  → post_entities: { post_id, entity_id, confidence: 0.95 }
  → Recommend cho user có interest "Kimetsu no Yaiba"
```

### Schema bổ sung
```sql
post_entities (post_id, entity_id, confidence FLOAT)
```

### Lợi ích
- User gõ "KNY", post viết "Demon Slayer" → vẫn match vì cùng entity_id
- Cross-language: "thanh gươm diệt quỷ" ≈ "Kimetsu no Yaiba"

---

## Semantic Search (đã thảo luận, chưa implement)

### Approach đã chọn: Embedding-based
- Mỗi user profile → vector (embedding model)
- Query → vector → tìm nearest neighbors
- Dùng `pgvector` extension cho PostgreSQL

### Model đã chốt: `mxbai-embed-large` (Ollama)
- `multilingual-e5` không có trên Ollama registry → không dùng được
- `mxbai-embed-large` — 670MB, chạy local qua Ollama, multilingual tốt
- Pull: `ollama pull mxbai-embed-large`

### Kết hợp với Entity Graph
```
Query: "tìm bạn thích hoạt hình Nhật"
  → Embedding similarity → candidates
  → Entity matching (Anime entities) → boost score
  → Return ranked results
```

---

## Thứ tự implement (đề xuất)

1. **Chip picker UI** cho interest selection (RegisterView)
2. **Option C schema** — migrate DB, update seed
3. **Entity table** + LLM normalization (async)
4. **pgvector** + embedding cho semantic search
5. **post_entities** + newsfeed personalization
