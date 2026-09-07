# Known Gaps — Deliberately Deferred

Scope decisions that were deliberately **not** implemented, with the reasoning, so
they don't get rediscovered as "silent" gaps later. Last reviewed 2026-09-07
during the full-app hardening pass.

---

## Half-built features — deliberately scoped as prototype

These exist in code but are not wired end-to-end. They are acceptable as
prototype surface for the project; finishing them is post-submission work.

- **Ward/commune location picker** (`Core/Components/WardPickerView.swift`,
  `WardRepository`, `WardDTO`/`ProvinceDTO`): built but not wired into onboarding
  (which uses a local province list) or Edit Profile (a plain text field).
  Kept for a future "structured address" feature.
- **Chat delivery receipts** (`MessageRepository` / `ChatViewModel` carry a
  `NOTE:` that the payload shape is assumed): the double-check-mark UI is present
  but the delivered/read distinction is not reliably driven by the backend.
  Read receipts work; "delivered" is best-effort.
- **Connections "sent requests" list**: the repository supports `pending_sent`
  but there is no UI section for outgoing requests; you can only see incoming
  ones. The connected-section header also reads "Friends" in Work mode.
- **`POST /api/posts/analyze` + `PostAnalyzeDTO`**: an earlier mode-mismatch
  path, now superseded by `notifRepository.fetchMismatchFor`. Left in place; not
  called by the shipping client.

## Backend — deferred query rewrites (correctness is fine; scale is not tuned)

- Feed ranking (`feedModel.js`) projects the vector distance for every candidate
  chunk instead of an `ORDER BY embedding <=> $vec LIMIT k` — HNSW is used for
  the pool, not the final rank. Fine at demo scale.
- `fetchVisiblePostMeta` (interaction routes) runs the full post projection as a
  permission check on every like/comment/save.
- `listPosts` runs a near-duplicate `countAll` per feed page.
- Notification fan-out (`birthdayJob`, `userNotifyService.emitToRecipients`,
  `meetingReminderJob`) does one `getUnreadCounts` query per recipient.
- Poll/event creation and `sendMessage` + `createMeetingProposal` are not yet
  wrapped in a transaction (the account/block/like/comment/connection paths are).
- Orphaned files under `backend/uploads/` (from deleted posts / recalled
  messages / expired stories) are not swept.

## iOS — error-UX rollout is partial

Phase 4 added the loading / error+Retry / empty pattern to Feed, Blocked Users,
Conversation List, Saved Posts, and Tag Feed. The same pattern still needs to be
applied to: Profile, User Profile, Chat, Comment Sheet, Recently Deleted, Chat
Settings, Chat Media Gallery, and `AppState.restoreSession` (which drops to Login
on any non-401 error instead of showing an offline/retry state).

---

## Push notifications (APNs)

**Status:** out of scope for this pass. In-app notifications (polling + WebSocket
`"notification"` event) work; background/closed-app push does not.

**Why deferred:** this isn't a code fix — it requires infrastructure this session
can't provision: an Apple Push Notification service key/certificate from the
project's Apple Developer account, device-token registration wired into the iOS
app, and a server-side APNs client (or a provider like Firebase Cloud Messaging)
to actually send pushes. None of that can be set up without real credentials from
the account owner.

**Current state:** honestly disclosed in-app — `NotificationSettingsView.swift`
already tells the user "Push notifications while the app is closed will arrive in
a future update."

**To pick this up:** decide APNs (native, needs a paid Apple Developer account +
`.p8` key) vs. FCM (works on a free tier, more setup); add device-token capture on
login (`UNUserNotificationCenter` registration + `POST /users/me/device-token`);
store tokens server-side; send from `messageService`/`notificationService` on
new-message / new-notification events alongside the existing WebSocket emit.
