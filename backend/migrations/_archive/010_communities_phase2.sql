-- Migration 010: Communities Phase 2
-- Adds: Polls, Events, Post-pinning, Notifications, Join Requests, Member Management
-- IMPORTANT: Only additive changes. No modification of existing tables/columns.

-- ── Extend posts ───────────────────────────────────────────────────────────────

ALTER TABLE posts
    ADD COLUMN post_type VARCHAR(10) NOT NULL DEFAULT 'text'
                         CHECK (post_type IN ('text', 'poll', 'event')),
    ADD COLUMN is_pinned BOOLEAN     NOT NULL DEFAULT FALSE,
    ADD COLUMN pinned_at TIMESTAMPTZ,
    ADD COLUMN pinned_by UUID REFERENCES users(id) ON DELETE SET NULL;

-- ── Poll options ───────────────────────────────────────────────────────────────

CREATE TABLE poll_options (
    id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id    UUID         NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    text       VARCHAR(200) NOT NULL,
    vote_count INTEGER      NOT NULL DEFAULT 0,
    position   SMALLINT     NOT NULL,
    ends_at    TIMESTAMPTZ
);

-- ── Poll votes (1 user · 1 vote per poll) ─────────────────────────────────────

CREATE TABLE poll_votes (
    poll_option_id UUID        NOT NULL REFERENCES poll_options(id) ON DELETE CASCADE,
    user_id        UUID        NOT NULL REFERENCES users(id)        ON DELETE CASCADE,
    voted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (poll_option_id, user_id)
);

-- ── Community events ───────────────────────────────────────────────────────────

CREATE TABLE community_events (
    id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id    UUID         NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
    title      VARCHAR(200) NOT NULL,
    location   VARCHAR(300),
    starts_at  TIMESTAMPTZ  NOT NULL,
    ends_at    TIMESTAMPTZ,
    rsvp_count INTEGER      NOT NULL DEFAULT 0
);

-- ── Event RSVPs ────────────────────────────────────────────────────────────────

CREATE TABLE event_rsvps (
    event_id UUID        NOT NULL REFERENCES community_events(id) ON DELETE CASCADE,
    user_id  UUID        NOT NULL REFERENCES users(id)            ON DELETE CASCADE,
    status   VARCHAR(10) NOT NULL DEFAULT 'going'
             CHECK (status IN ('going', 'maybe', 'not_going')),
    rsvp_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (event_id, user_id)
);

-- ── Community notifications ────────────────────────────────────────────────────

CREATE TABLE community_notifications (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    user_id      UUID        NOT NULL REFERENCES users(id)       ON DELETE CASCADE,
    type         VARCHAR(30) NOT NULL
                 CHECK (type IN (
                     'new_post', 'pinned_post',
                     'join_request', 'join_approved', 'join_rejected',
                     'role_changed'
                 )),
    ref_id       UUID,
    is_read      BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Join requests (private communities) ───────────────────────────────────────

CREATE TABLE community_join_requests (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    user_id      UUID        NOT NULL REFERENCES users(id)       ON DELETE CASCADE,
    status       VARCHAR(10) NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected')),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_by  UUID REFERENCES users(id),
    reviewed_at  TIMESTAMPTZ,
    UNIQUE (community_id, user_id)
);

-- ── Indexes ────────────────────────────────────────────────────────────────────

CREATE INDEX idx_notifications_user      ON community_notifications(user_id, is_read, created_at DESC);
CREATE INDEX idx_join_requests_community ON community_join_requests(community_id, status);
CREATE INDEX idx_poll_options_post       ON poll_options(post_id, position);
CREATE INDEX idx_events_starts_at        ON community_events(starts_at);
