-- ─────────────────────────────────────────────────────────────────────────────
-- 024 — Voice messages in chat
--
-- Adds a 'voice' message type, structurally the same "type + optional
-- media_url + optional extra fields" shape 'image'/'video' already use.
-- Waveform samples are captured once client-side at record time (a compact
-- fixed-length array of ~40 normalized 0.0-1.0 amplitude floats) and sent
-- alongside the audio file, so every viewer renders the identical waveform
-- with no server-side audio processing (ffmpeg etc.) ever needed.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE messages DROP CONSTRAINT messages_message_type_check;
ALTER TABLE messages ADD CONSTRAINT messages_message_type_check
  CHECK (message_type IN ('text', 'image', 'video', 'meeting', 'voice'));

ALTER TABLE messages ADD COLUMN voice_duration_seconds INTEGER;
ALTER TABLE messages ADD COLUMN voice_waveform REAL[];
