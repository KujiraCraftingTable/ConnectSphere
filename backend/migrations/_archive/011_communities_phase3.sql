-- Migration 011: Communities Phase 3
-- Adds: Reports/Moderation, Analytics, Recommendation, Discovery, Bans
-- No modifications to existing columns. Only additive changes.

-- ── Extend notification types ─────────────────────────────────────────────────

ALTER TABLE community_notifications
    DROP   CONSTRAINT community_notifications_type_check,
    ADD    CONSTRAINT community_notifications_type_check
           CHECK (type IN (
               'new_post', 'pinned_post',
               'join_request', 'join_approved', 'join_rejected',
               'role_changed', 'new_report'
           ));

-- ── Reports ───────────────────────────────────────────────────────────────────

CREATE TABLE community_reports (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id  UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_type  VARCHAR(10) NOT NULL CHECK (target_type IN ('post', 'member')),
    target_id    UUID        NOT NULL,
    community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    reason       VARCHAR(30) NOT NULL
                 CHECK (reason IN (
                     'spam', 'harassment', 'hate_speech',
                     'misinformation', 'off_topic', 'other'
                 )),
    detail       TEXT,
    status       VARCHAR(10) NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'resolved', 'dismissed')),
    resolved_by  UUID REFERENCES users(id),
    resolved_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (reporter_id, target_type, target_id)
);

-- ── Analytics (daily snapshots) ───────────────────────────────────────────────

CREATE TABLE community_analytics (
    id             UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    community_id   UUID    NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    snapshot_date  DATE    NOT NULL,
    member_count   INTEGER NOT NULL DEFAULT 0,
    post_count     INTEGER NOT NULL DEFAULT 0,
    new_members    INTEGER NOT NULL DEFAULT 0,
    new_posts      INTEGER NOT NULL DEFAULT 0,
    active_members INTEGER NOT NULL DEFAULT 0,
    UNIQUE (community_id, snapshot_date)
);

-- ── Recommendation interests (per-user tag weights) ───────────────────────────

CREATE TABLE recommendation_interests (
    user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tag        VARCHAR(50) NOT NULL,
    weight     FLOAT       NOT NULL DEFAULT 1.0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, tag)
);

-- ── Community tags (for recommendation matching) ──────────────────────────────

CREATE TABLE community_tags (
    community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    tag          VARCHAR(50) NOT NULL,
    PRIMARY KEY (community_id, tag)
);

-- ── Trending score cache ──────────────────────────────────────────────────────

CREATE TABLE community_trending (
    community_id UUID  NOT NULL REFERENCES communities(id) ON DELETE CASCADE PRIMARY KEY,
    score        FLOAT NOT NULL DEFAULT 0,
    computed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Community bans (permanent. Prevents rejoin) ──────────────────────────────

CREATE TABLE community_bans (
    community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
    user_id      UUID        NOT NULL REFERENCES users(id)       ON DELETE CASCADE,
    banned_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    banned_by    UUID REFERENCES users(id) ON DELETE SET NULL,
    PRIMARY KEY (community_id, user_id)
);

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE INDEX idx_reports_community   ON community_reports(community_id, status);
CREATE INDEX idx_reports_target      ON community_reports(target_type, target_id);
CREATE INDEX idx_analytics_community ON community_analytics(community_id, snapshot_date DESC);
CREATE INDEX idx_community_tags_tag  ON community_tags(tag);
CREATE INDEX idx_rec_interests_user  ON recommendation_interests(user_id, weight DESC);
CREATE INDEX idx_trending_score      ON community_trending(score DESC);
CREATE INDEX idx_bans_community      ON community_bans(community_id);
