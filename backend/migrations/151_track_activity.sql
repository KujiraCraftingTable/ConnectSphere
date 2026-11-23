-- ─────────────────────────────────────────────────────────────────────────────
-- 151, "Personalise with my activity" (Law 91/2025 Art. 29.4)
--
-- Social networks must offer a "do not track" choice. Personalisation stays on
-- by default (it is part of the service the Terms describe); turning it off
-- stops recording views, dwell time and search taps, and stops likes, comments,
-- saves and views from shaping anyone's ranking. What was recorded is erased
-- when it is turned off (ActivityTracking.erase).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users ADD COLUMN track_activity BOOLEAN NOT NULL DEFAULT TRUE;
