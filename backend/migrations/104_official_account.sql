-- The official ConnectSphere account is the app's only admin (moderators can
-- still be several). Enforced here, not only in the CLI, so a second admin
-- can never appear by a hand-written UPDATE either. Deleted rows don't count:
-- a deleted admin must not block naming a new one.
CREATE UNIQUE INDEX IF NOT EXISTS users_single_admin
  ON users ((TRUE))
  WHERE app_role = 'admin' AND deleted_at IS NULL;
