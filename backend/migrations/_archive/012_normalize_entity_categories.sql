-- Normalize interest_entities.category to match entity_type format used in aiService:
-- Old: 'Anime', 'Movies', 'Gaming', 'Music', 'Books'
-- New: 'anime', 'movie',  'game',   'music', 'book'
UPDATE interest_entities SET category = 'anime' WHERE category = 'Anime';
UPDATE interest_entities SET category = 'movie' WHERE category = 'Movies';
UPDATE interest_entities SET category = 'game'  WHERE category = 'Gaming';
UPDATE interest_entities SET category = 'music' WHERE category = 'Music';
UPDATE interest_entities SET category = 'book'  WHERE category = 'Books';
