/**
 * notificationTypes.js — the single registry of every notification type.
 *
 * `user_notifications.type` has no CHECK constraint (unlike the retired
 * community_notifications table, whose CHECK turned "add a type" into a schema
 * migration), so this whitelist is what validates a type instead.
 *
 * Each entry declares:
 *   category   — social | community | chat, used for scoped counts and filters
 *   entityType — what entity_id points at when the caller doesn't say
 *   destination— which screen the client opens when the row is tapped
 *
 * Pure module: no imports, no I/O, so it is unit-testable without a database.
 */

const CATEGORIES = ['social', 'community', 'chat'];

// Destination kinds the iOS client switches on. Computed at read time by
// buildDestination() and never stored, so fixing a navigation bug is a backend
// change rather than an App Store release.
const DESTINATIONS = {
  NONE:            'none',            // rendered inline, does not navigate
  POST:            'post',
  PROFILE:         'profile',
  CONVERSATION:    'conversation',
  CONVERSATIONS:   'conversations',   // the chat list
  COMMUNITY:       'community',
  COMMUNITY_POST:  'communityPost',
  COMMUNITY_JOINS: 'communityJoinRequests',
  COMMUNITY_REPORTS: 'communityReports',
};

const NOTIFICATION_TYPES = {
  // ─── social ───────────────────────────────────────────────────────────────
  post_liked:          { category: 'social', entityType: 'post',    destination: DESTINATIONS.POST },
  post_commented:      { category: 'social', entityType: 'comment', destination: DESTINATIONS.POST },
  comment_replied:     { category: 'social', entityType: 'comment', destination: DESTINATIONS.POST },
  comment_liked:       { category: 'social', entityType: 'comment', destination: DESTINATIONS.POST },
  post_shared:         { category: 'social', entityType: 'post',    destination: DESTINATIONS.POST },
  connection_request:  { category: 'social', entityType: 'user',    destination: DESTINATIONS.PROFILE },
  connection_accepted: { category: 'social', entityType: 'user',    destination: DESTINATIONS.PROFILE },
  birthday:            { category: 'social', entityType: 'user',    destination: DESTINATIONS.PROFILE },
  // The AI mode suggestion is answered inline with Keep / Switch buttons.
  mode_mismatch:       { category: 'social', entityType: 'post',    destination: DESTINATIONS.NONE },

  // ─── chat ─────────────────────────────────────────────────────────────────
  message:           { category: 'chat', entityType: 'conversation', destination: DESTINATIONS.CONVERSATION },
  meeting_proposed:  { category: 'chat', entityType: 'meeting',      destination: DESTINATIONS.CONVERSATION },
  meeting_updated:   { category: 'chat', entityType: 'meeting',      destination: DESTINATIONS.CONVERSATION },
  meeting_rsvp:      { category: 'chat', entityType: 'meeting',      destination: DESTINATIONS.CONVERSATION },
  meeting_reminder:  { category: 'chat', entityType: 'meeting',      destination: DESTINATIONS.CONVERSATION },
  message_reaction:  { category: 'chat', entityType: 'message',      destination: DESTINATIONS.CONVERSATION },
  group_added:       { category: 'chat', entityType: 'conversation', destination: DESTINATIONS.CONVERSATION },
  // They can no longer open the conversation, so send them to the chat list.
  group_removed:     { category: 'chat', entityType: 'conversation', destination: DESTINATIONS.CONVERSATIONS },

  // ─── community ────────────────────────────────────────────────────────────
  new_post:        { category: 'community', entityType: 'post',         destination: DESTINATIONS.COMMUNITY_POST },
  pinned_post:     { category: 'community', entityType: 'post',         destination: DESTINATIONS.COMMUNITY_POST },
  join_request:    { category: 'community', entityType: 'join_request', destination: DESTINATIONS.COMMUNITY_JOINS },
  join_approved:   { category: 'community', entityType: 'join_request', destination: DESTINATIONS.COMMUNITY },
  join_rejected:   { category: 'community', entityType: 'join_request', destination: DESTINATIONS.COMMUNITY },
  role_changed:    { category: 'community', entityType: 'community',    destination: DESTINATIONS.COMMUNITY },
  new_report:      { category: 'community', entityType: 'report',       destination: DESTINATIONS.COMMUNITY_REPORTS },
  // The post is hard-deleted by the time this fires, so there is nothing to
  // open — send them to the community instead.
  content_removed: { category: 'community', entityType: 'community',    destination: DESTINATIONS.COMMUNITY },
};

// Is this a type the app knows how to render and route?
function isKnownType(type) {
  return Object.prototype.hasOwnProperty.call(NOTIFICATION_TYPES, type);
}

// Which category a type belongs to, or null for an unknown type
function categoryOf(type) {
  return NOTIFICATION_TYPES[type]?.category ?? null;
}

// The default entity_type for a notification type, or null if unknown
function entityTypeOf(type) {
  return NOTIFICATION_TYPES[type]?.entityType ?? null;
}

// Every type in a category — drives the `type = ANY($n)` filter in listForUser
function typesForCategory(category) {
  if (!category || category === 'all') return null;
  return Object.keys(NOTIFICATION_TYPES)
    .filter((type) => NOTIFICATION_TYPES[type].category === category);
}

/**
 * Stable key used by the client to collapse rows into "Anna and 2 others
 * liked your post".
 *
 * Note the grouping target is NOT always entity_id: post_commented stores the
 * comment id in entity_id (so tapping can scroll to that comment) but must
 * group by the post, otherwise every comment becomes its own row.
 * Callers pass the grouping target explicitly for those cases.
 */
function buildGroupKey(type, targetId) {
  return `${type}:${targetId ?? 'none'}`;
}

/**
 * Where tapping this notification should take the user. Computed from the
 * stored columns at read time — never persisted.
 */
function buildDestination(row) {
  const kind = NOTIFICATION_TYPES[row.type]?.destination ?? DESTINATIONS.NONE;
  const payload = row.payload ?? {};

  switch (kind) {
    case DESTINATIONS.POST:
      return {
        kind,
        postId:    row.post_id ?? payload.postId ?? null,
        commentId: payload.commentId ?? null,
      };

    case DESTINATIONS.PROFILE:
      return { kind, userId: row.actor_id ?? payload.fromUserId ?? null };

    case DESTINATIONS.CONVERSATION:
      return {
        kind,
        conversationId: row.conversation_id ?? payload.conversationId ?? null,
        messageId:      payload.messageId ?? null,
      };

    case DESTINATIONS.CONVERSATIONS:
      return { kind };

    case DESTINATIONS.COMMUNITY_POST:
      return {
        kind,
        communityId: row.community_id ?? null,
        postId:      row.post_id ?? payload.refId ?? null,
      };

    case DESTINATIONS.COMMUNITY_JOINS:
    case DESTINATIONS.COMMUNITY_REPORTS:
    case DESTINATIONS.COMMUNITY:
      return { kind, communityId: row.community_id ?? null };

    default:
      return { kind: DESTINATIONS.NONE };
  }
}

module.exports = {
  CATEGORIES,
  DESTINATIONS,
  NOTIFICATION_TYPES,
  isKnownType,
  categoryOf,
  entityTypeOf,
  typesForCategory,
  buildGroupKey,
  buildDestination,
};
