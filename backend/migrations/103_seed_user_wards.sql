-- Distance search measures from users.ward_id, but nothing wrote it until
-- sign-up started asking for a ward, so every existing account (all seeded)
-- had none and fell out of any radius search. Give each one a Ho Chi Minh
-- City ward, picked from a hash of its id so the pick is stable, and make the
-- public location match. Accounts that already have a ward keep it.
WITH hcm AS (
  SELECT id, (row_number() OVER (ORDER BY code) - 1) AS n, count(*) OVER () AS total
  FROM vn_wards WHERE province_name_en = 'Ho Chi Minh City'
)
UPDATE users u
SET ward_id = h.id, location = 'Ho Chi Minh'
FROM hcm h
WHERE u.ward_id IS NULL
  AND u.deleted_at IS NULL
  AND h.n = (hashtext(u.id::text)::bigint & 2147483647) % h.total;
