-- ─────────────────────────────────────────────────────────────────────────────
-- 053 — Strip blank edges from existing post text
--
-- Post text was trimmed of spaces but not line breaks, so a caption could
-- end in a run of empty lines (a big blank gap on the card). New text is
-- trimmed of both now; this cleans the posts written before. Line breaks
-- inside the text are kept.
--
-- A translation is tied to its source text by `translated_hash`, so it is
-- re-pointed to the trimmed text where it matched the old one — the
-- translation of "text⏎⏎" is the translation of "text", and keeping it
-- spares the local model a re-translation of every one of these posts.
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE posts
SET content = btrim(content, E' \t\n\r'),
    translated_hash = CASE
      WHEN translated_hash = encode(sha256(convert_to(coalesce(content, ''), 'UTF8')), 'hex')
      THEN encode(sha256(convert_to(btrim(content, E' \t\n\r'), 'UTF8')), 'hex')
      ELSE translated_hash
    END
WHERE content ~ '^[[:space:]]' OR content ~ '[[:space:]]$';
