-- When each person last left the Notifications tab, per mode. The tab badge
-- counts only unread notifications that arrived after it, like Facebook: the
-- badge clears once you've looked, while each notification stays unread until
-- it's opened. No row yet means every unread notification counts.
CREATE TABLE IF NOT EXISTS notification_seen (
  user_id  UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  mode     VARCHAR(10) NOT NULL CHECK (mode IN ('hobby', 'work')),
  seen_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, mode)
);
