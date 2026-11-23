-- ─────────────────────────────────────────────────────────────────────────────
-- 149, Landmarks the geocoder doesn't know by the name people use
--
-- "iOS developers near Landmark 81" found no one: the public geocoder has no
-- place called "Landmark 81" (the tower is "Vincom Landmark 81" there, under
-- its shops) and answered with "PetroVietnam Landmark", an apartment block in
-- Phường Bình Trưng. Search now refuses a geocoder answer that drops a number
-- of the name (`VenueLocationService.namesTheSame`) and first looks in these
-- checked aliases (`VenueLocationService.knownPlace`), whose coordinates pick
-- the nearest ward: Landmark 81 is 0.65 km from the centre of Phường Thạnh Mỹ
-- Tây.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO location_aliases (alias, canonical, province_name, lat, lng, status, reviewed_at)
VALUES
  ('landmark 81', 'Vincom Landmark 81', 'Ho Chi Minh', 10.7950, 106.7219, 'validated', now()),
  ('vincom landmark 81', 'Vincom Landmark 81', 'Ho Chi Minh', 10.7950, 106.7219, 'validated', now()),
  ('landmark81', 'Vincom Landmark 81', 'Ho Chi Minh', 10.7950, 106.7219, 'validated', now())
ON CONFLICT (alias) DO UPDATE
  SET canonical = EXCLUDED.canonical, province_name = EXCLUDED.province_name,
      lat = EXCLUDED.lat, lng = EXCLUDED.lng, status = 'validated', reviewed_at = now();
