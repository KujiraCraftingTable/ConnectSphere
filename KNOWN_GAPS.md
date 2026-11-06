# Known Gaps, Deliberately Deferred

Scope decisions that were deliberately **not** implemented, with the reasoning, so
they don't get rediscovered as "silent" gaps later. Last reviewed 2026-11-06
against the code (docs refresh).

---

## Half-built features, deliberately scoped as prototype

These exist in code but are not wired end-to-end. They are acceptable as
prototype surface for the project; finishing them is post-submission work.

- **Interest suggestions have no review screen** (`interest_suggestions`,
  migration 080): there is no app-wide admin role, so suggestions are reviewed
  in the database and added to `interest_catalog` by hand.
- **Dating is archived, not running.** The app is for friends and colleagues;
  finding a partner is deliberately out of scope. The code lives in
  `legacy/dating/` (see its README to restore it). The database keeps the
  inert `dating_*` tables and `conversations.dating_match_id`
  (migrations 081–082); nothing reads or writes them. AI search ignores
  partner wording ("to date", "người yêu") and searches the rest.

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

## Backend, deferred query rewrites (correctness is fine; scale is not tuned)

- The Home feed ranks a capped candidate set (`FeedStore.maxCandidates` = 400
  posts from the last 60 days) in SQL rather than doing an
  `ORDER BY embedding <=> $vec LIMIT k` over everything. Fine at demo scale.
- The post list runs a near-duplicate `PostStore.countAll` per feed page.
- Not re-checked since the first version: notification
  fan-out issues one unread-count query per recipient, and
  `sendMessage` / `createMeetingProposal` are not wrapped in a transaction.
- Orphaned files under `backend/uploads/` (from deleted posts / recalled
  messages / expired stories) are not swept.

## iOS, design-system rollout is partial

A token layer (`Core/Theme/AppMetrics.swift`: `AppFont`, `AppSpacing`,
`AppRadius`, `AppElevation`) + shared components (`Core/UI/`: `Avatar`, `Chip`,
`CountBadge`, `ListRow`, `SectionHeader`, `PrimaryButton`, `EmptyStateView`)
were added, `AppTheme`/`AppGradient` deleted, the Feed migrated as the visual
reference, and the loud palette-on-chip / stray-`.orange`/`.purple` problems
swept app-wide. Still mechanical follow-up:

- ~1,090 inline `.font(.system(size:))` sites still need `.appFont(_:)`
  (grown with the new features). `scripts/lint-design.sh` budget-checks the
  count, but its budget (638) is now below the real count, so the script
  fails until the budget is raised or the sites are migrated.
- `settingsRow` (×2 copies) → `ListRow`; the ~13 hand-rolled avatar circles in
  Chat / Notifications → `Avatar`.
- `FeedView.chatIconButton` / `ProfileView.navIconButton` bespoke filled circles
  → plain toolbar buttons.
- `SearchView`'s ~5 stacked info panels → one `InfoPanel`.
- `ThemePickerView` still uses `Color(.systemGroupedBackground)` (a cool-grey
  seam against the warm base) and heavy `primaryGradient`.
- `%d` → `%lld` in ~24 `String(format: bundle.loc(...))` sites (correctness nit
  only, no value reaches 2³¹; each needs a matching key rename in both
  `.strings` files).

## iOS, error-UX rollout is partial

Phase 4 added the loading / error+Retry / empty pattern (`Core/UI/ContentStateView.swift`)
to Feed, Blocked Users, Conversation List, Saved Posts, and Tag Feed. The same
pattern still needs to be applied to: Profile, User Profile, Chat, Comment Sheet,
Recently Deleted, Chat Settings and Chat Media Gallery (not re-audited screen by
screen in the 2026-11 review). `AppState.restoreSession` now keeps the saved
login on a network error and opens from the cached profile.

---

## Upload metadata, the server's safety net covers JPEG/PNG only

The app strips GPS, capture date, camera model and other metadata from every
photo and video before upload (`Core/Media/MediaSanitizer.swift`), and the
server strips JPEG/PNG again on arrival (`Infra/MetadataStripper.swift`). Two
deliberate limits on the server side, which only matter for a client other
than this app:

- HEIC, WebP, MP4 and MOV are stored as received. Stripping them server-side
  needs an image/video library (a new dependency).
- Stripping a JPEG's EXIF also drops its orientation flag; the app bakes the
  rotation into the pixels first, but another client's sideways-flagged JPEG
  would be stored sideways.

---

## Push notifications (APNs)

**Status:** out of scope for this pass. In-app notifications (polling + WebSocket
`"notification"` event) work; background/closed-app push does not.

**Why deferred:** this isn't a code fix. It requires infrastructure this session
can't provision: an Apple Push Notification service key/certificate from the
project's Apple Developer account, device-token registration wired into the iOS
app, and a server-side APNs client (or a provider like Firebase Cloud Messaging)
to actually send pushes. None of that can be set up without real credentials from
the account owner.

**Current state:** honestly disclosed in-app, `NotificationSettingsView.swift`
already tells the user "Push notifications while the app is closed will arrive in
a future update."

**To pick this up:** decide APNs (native, needs a paid Apple Developer account +
`.p8` key) vs. FCM (works on a free tier, more setup); add device-token capture on
login (`UNUserNotificationCenter` registration + `POST /users/me/device-token`);
store tokens server-side; send from `messageService`/`notificationService` on
new-message / new-notification events alongside the existing WebSocket emit.
