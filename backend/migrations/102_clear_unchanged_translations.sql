-- A translation identical to its source (the model handed the text back) made
-- the app label unchanged text "Translated by AI". The server no longer stores
-- these; clear the ones already saved. translated_hash stays, so they aren't redone.
UPDATE posts
SET translated_text = NULL
WHERE translated_text IS NOT NULL AND lower(btrim(translated_text)) = lower(btrim(content));

UPDATE comments
SET translated_text = NULL
WHERE translated_text IS NOT NULL AND lower(btrim(translated_text)) = lower(btrim(content));
