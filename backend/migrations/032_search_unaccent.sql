-- Accent-insensitive keyword search: "meo" should find "Mèo", "nguyen" should
-- find "Nguyễn". Keyword ranking folds both the stored text and the query
-- with unaccent(lower(...)). Ships with Postgres contrib; no new package.
CREATE EXTENSION IF NOT EXISTS unaccent;
