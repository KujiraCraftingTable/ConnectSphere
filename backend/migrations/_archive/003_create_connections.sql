-- Migration 003: connections (friend / colleague requests)

CREATE TABLE connections (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  addressee_id UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,

  -- Which mode this connection belongs to
  mode         VARCHAR(20) NOT NULL CHECK (mode IN ('friend', 'colleague')),

  status       VARCHAR(20) NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'accepted', 'rejected', 'blocked')),

  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- One pending/accepted pair per mode; a user cannot send duplicate requests
  UNIQUE (requester_id, addressee_id, mode),
  -- Cannot connect with yourself
  CHECK (requester_id <> addressee_id)
);

CREATE INDEX idx_connections_requester ON connections (requester_id);
CREATE INDEX idx_connections_addressee ON connections (addressee_id);
CREATE INDEX idx_connections_status    ON connections (status);

-- ── Auto-update updated_at ────────────────────────────────────────────────────

CREATE TRIGGER trg_connections_updated_at
  BEFORE UPDATE ON connections
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
