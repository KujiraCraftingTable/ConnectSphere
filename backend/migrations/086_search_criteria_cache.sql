-- ─────────────────────────────────────────────────────────────────────────────
-- 086, Reading of a search prompt, reused
--
-- Turning a prompt into search criteria is the slowest step of AI search (an
-- LLM call of up to 60 s while Ollama is busy). The same prompt in the same
-- mode reads the same way, so its criteria are kept for a day
-- (`OllamaService.criteriaCacheHours`). A failed reading is never stored.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS search_criteria_cache (
  -- "<mode or ->|<prompt, lowercased, spaces collapsed>"
  key        TEXT        PRIMARY KEY,
  criteria   JSONB       NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
