-- ─────────────────────────────────────────────────────────────────────────────
-- 150, "iOS development" is not ISO Development Environment
--
-- The catalogue entity "ISO Development Environment" (a software brand) had
-- "iOS development" as an alias, so every profile with the iOS development
-- skill was embedded as "iOS development (ISO Development Environment)"
-- (`ChunkService.canonicalizeTerm`). The alias goes, and the profile chunks
-- built with it are dropped; the chunk sweep rebuilds them.
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE interest_entities
SET aliases = array_remove(aliases, 'iOS development')
WHERE canonical_name = 'ISO Development Environment';

DELETE FROM user_embedding_chunks
WHERE source_type = 'user_profile' AND content ILIKE '%(ISO Development Environment)%';
