-- ─────────────────────────────────────────────────────────────────────────────
-- 148, English ward names: the kind goes last, numbered names included
--
-- vn_wards (003) spells a unit in English as "<Name> Ward" / "<Name> Commune"
-- ("Sai Gon Ward"), except for 37 units whose name carries a number, which
-- were seeded the other way round: "Ward Ha Giang 2", "Commune A Luoi 1",
-- "Ward 1 Bao Loc". They now follow the rule everything else does, and that
-- the app applies when it shows a job's address or a former ward in English:
-- "Ha Giang 2 Ward", "A Luoi 1 Commune", "1 Bao Loc Ward".
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE vn_wards
SET full_name_en = regexp_replace(full_name_en, '^(Ward|Commune) (.+)$', '\2 \1')
WHERE full_name_en ~ '^(Ward|Commune) ';
