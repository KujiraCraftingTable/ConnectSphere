-- 097, Sign-in alerts saved before the device name was sent as UTF-8 show
-- "iPhone � iOS 27.0": the "·" separator was mangled in an HTTP header. The
-- separator is the only character that was ever replaced, so put it back.
UPDATE user_notifications
SET payload = jsonb_set(payload, '{device}', to_jsonb(replace(payload->>'device', U&'\FFFD', '·')))
WHERE type = 'new_login' AND payload->>'device' LIKE '%' || U&'\FFFD' || '%';
