# Known Gaps, Deliberately Deferred

Scope decisions that were deliberately **not** implemented, with the reasoning, so
they don't get rediscovered as "silent" gaps later. Last reviewed 2026-11-06
against the code (docs refresh).

---

## Half-built features, deliberately scoped as prototype

These exist in code but are not wired end-to-end. They are acceptable as
prototype surface for the project; finishing them is post-submission work.

- **Interest suggestions have no review screen** (`interest_suggestions`,
  migration 080): app admins exist now (migration 089) but their queue covers
  reports only, so suggestions are still reviewed in the database and added to
  `interest_catalog` by hand.
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

## The official account: one admin, made from the command line

`@connectsphere` is the app's only admin (`users.app_role = 'admin'`, at most
one by migration 104), with the seal and an "Admin" capsule beside its name
(comments show the "Admin" capsule, like "Author"). It can't be reported,
blocked or deleted (`OfficialAccount`). Its rules:

- **Followers, no connections.** Anyone can follow it; it follows no one and
  sends or accepts no friend requests. Its app has no UI for any of it: no
  Add friend, Follow, People you may know, Connections/Following feeds,
  Join or Create community, or friend-request setting.
- **Communities without joining.** It reads any community, public or private,
  and can like, comment and share there, but not join, post, save or moderate; each
  community's own admins and moderators keep those (`can_view`,
  `officialReads`). Its Home feed and search never show private communities.
- **Posts per mode, with cross-posting.** Its composer has "Post in Hobby and
  Work" (text posts on its own feed), which publishes one post in each mode.
- **Least information.** Only its name and pictures can change; no location,
  birthday, about, work, education, interests or skills (`official-account
  tidy` resets them, and `PATCH /users/me` drops those fields).
- **Support inbox, replies only.** Anyone can message it, with no 3-message
  limit; it lands in its Waiting requests. It never writes first: no new
  chats, no groups, and no message into a chat until the other person wrote.
- **Admin tools**, its own section at the top of Settings: Review reports (the
  moderation queue), counts per mode, and looking up one account (no email,
  phone, birthday or messages).
- **Warns and bans, never reports or blocks.** Wherever people see Report
  (post, comment, message, profile), the official account sees "Warn or ban".
  Both go through a case, so the person gets a notification, an email (if
  their email is verified) and can appeal.
- **Bans are per mode** (`account_bans`, migration 106): permanent or 7, 30,
  90 or 365 days, lifting themselves when they end. Banned in a mode, that
  persona disappears there (profile, posts, comments, stories, search,
  suggestions) and nobody can follow, connect with or message it; old
  messages stay. The app sends `X-App-Mode`, and the person sees only the
  ban notice in that mode (reason, until when, the content it was about,
  email and in-app appeal, switch to the other mode). Banned in both modes
  is the whole account; permanent in both also blocks that email and Google
  account from signing up again (`banned_identities`).
- **Warnings** count in their mode for 90 days; a third must be a ban, and
  the admin picks how long. People see their warnings, with the content, in
  Settings > Manage account > Account status ("Healthy" when there are none).
- **Locked profiles stay out of other people's feeds.** A locked persona's
  posts reach only its friends; the official account still sees and opens
  everything (locked, friends-only, private communities, banned personas).

Deliberately left out:

- **No sign-up for it.** `swift run App official-account claim --user <name>
  --commit` turns an existing account into it, erasing everything that account
  had but keeping its email, password and 2FA. Without `--commit` it's a dry
  run. Moderators can still be added with `moderator grant`.
- **No boost in the feed.** Its posts are ranked like anyone's; people see
  them by following it.
- **Cross-posting covers text posts only**; polls, events and jobs go to one
  mode. The two copies are separate posts, published one after the other.
- **One admin is one point of failure.** A lost password goes through the
  normal password reset; there is no second admin to step in.

## Moderation: reports, admins, appeals, and automatic text checks

Users report anything; app moderators and the one admin decide in
Settings › Moderation or with
`swift run App moderation`; authors get strikes, restrictions or bans and can
appeal from Settings › Account status. Text is checked automatically: word
rules before saving (with an "Are you sure?" for rude wording in comments and
chat), per-account rate limits, a local Qwen3Guard check after publishing, and
behaviour-based spam signals in chat (`ModerationRules`, `UserRateLimiter`,
`ModerationScan`, `SpamSignals`). Deliberately not done yet:

- **The AI check starts in `shadow` mode** (`MODERATION_MODE`): it opens cases
  in Held by AI but hides nothing. `swift run App moderation-eval
  server/Tests/Fixtures/moderation_eval.jsonl` scores it; on the 198-item
  hand-made set the 4B model wrongly flagged 0 of 90 ordinary messages and
  caught 92% of 108 harmful ones. That set is small and was written by one
  person, so check Held by AI on real data for a while before `enforce`.
  Known misses: threats and self-harm typed without accents ("may lieu hon"),
  and "hàng trắng" for drugs.
- **Photo checks need `OPENAI_API_KEY`** (migration 090): every uploaded
  photo is sent to OpenAI's free moderation endpoint (sexual, graphic violence,
  self-harm), and content using a flagged photo is held like a flagged text.
  Without a key every photo is recorded as `unscanned`. **The OpenAI call was
  never run against the real service** (no key during development); the rest
  of the flow — the verdict set by hand — was tested. Not covered: videos and
  HEIC/HEIF files (marked `unscanned`), chat photos (never scanned; reports and
  the blur for strangers in Waiting), minors in images (OpenAI doesn't judge
  them in photos), outside link-preview pictures on link posts, and
  re-encoded copies of a removed photo (only the exact same bytes are refused).
  Dating profiles are shown only once every photo has been checked, and only
  while `MODERATION_MODE=enforce` and a key are set.
- **Photos must be our own uploads** (posts, comments, stories, avatars,
  covers, communities, group photos): a link to another site is refused, except
  the preview picture of a link post, and an old post keeps the image it has.
- **Chat is never read by the AI** — only reports, the word rules before
  sending, and spam signals — and the OpenAI second opinion (needs
  `OPENAI_API_KEY`) never sees chat text.
- **Rate limits and spam counters live in the server process**, so a restart
  resets them; sharing them needs a Redis client (a new dependency).
- **Profanity in a post isn't nudged**, only refused when it is a threat or
  slur: milder wording waits for a report.
- **A suspended community's posts stay in feeds**; only the community itself
  drops out of lists and search.
- **No push for notices**, like every notification (see below).
- **Restriction isn't checked on every write**: posting, sharing, comments,
  stories, communities, listings and new message requests refuse it; edits
  and replies in existing chats don't.

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

---

## Age is self-declared (no verified age, no phone verification)

**Status:** sign-up and Edit profile reject a birthday under 16
(`BirthdayRules.minimumAge`), but nothing checks the birthday is true. The app
also does not verify accounts by Vietnamese phone number.

**Why deferred:** a person's real birthday sits with the national ID (CCCD)
database. An SMS code only proves someone holds a number; carriers do not hand
the ID birthday to apps (their KYC APIs are paid, business-to-business). The
government's plan to link social networks to VNeID was still at design stage
(target Q3 2026) with no route for third-party apps that we found. Asking users
for photos of their ID is not allowed for social networks (Law 91/2025 Art. 29),
and reading the ID chip over NFC needs a paid Apple Developer account, a real
device and a lawyer's view on holding ID data.

**What the rules ask for (to confirm with a lawyer before any public launch):**
Decree 147/2024 asks social networks to verify accounts by Vietnamese phone
number, and to have a parent register accounts for under-16s. We choose not to
offer under-16 accounts instead.

**Existing accounts:** an account created before this rule with a birthday under
16 is not locked automatically — find them with
`SELECT id, username FROM users WHERE dob > CURRENT_DATE - INTERVAL '16 years'`.

**To pick this up:** register a business and a paid Apple account, then use
either VNeID linking (once opened) or a carrier/KYC provider, and add a parent
registration flow only if under-16s are ever admitted.

---

## No "personalised feed" off switch

**Status:** the feed and AI search rank with what a person likes, views, saves and
searches (`post_impressions`, `post_feedback`, `search_sessions`; kept 90 days). The
Privacy Policy says so, and deleting the account removes it, but there is no setting
to turn the ranking off while staying signed in.

**Why deferred:** a non-personalised feed is a second ranking path in `FeedStore` /
`PostRanking`, with its own tests; it is not small. Vietnam's Law 91/2025 asks that
people can refuse behaviour tracking on social networks (Art. 29) — confirm with a
lawyer whether in-app ranking from your own activity counts.

**To pick this up:** add `users.personalised_feed BOOLEAN DEFAULT TRUE`, skip the
signals when off (no impressions or feedback written, ranking by recency and mode),
and a switch in Settings › Privacy & Security.

---

## Accessibility: text sizes and what was not checked

**Done:** about 1,070 fixed font sizes now follow the user's text-size setting
(`.scaledFont` in `Core/Theme/AppMetrics.swift`); the app-wide cap is the largest
non-accessibility size (xxxLarge, `cappedDynamicType`); tertiary and secondary
text colours meet WCAG AA (4.5:1) on the app's backgrounds; icon-only buttons
got spoken labels.

**Still open:**
- **Accessibility sizes (AX1 and up) are capped.** Dense screens with fixed-height
  controls (feed card actions, chat input bar) would clip above xxxLarge. Lifting
  the cap needs each of those screens checked in the simulator.
- **57 fixed font sizes remain** (sizes written as `compact ? 10 : 11`, or with
  `.monospacedDigit()`); they do not grow.
- **Not tested with VoiceOver on a device or simulator.** Labels were added from a
  code scan for icon-only buttons; reading order, custom gestures (swipes, long
  presses) and images without alt text were not reviewed.
- **Contrast of text on photos, coloured chips and theme-coloured buttons** was not
  measured; only the shared text colour tokens were.
- **Reduce Motion** is honoured in two places only.

## Tracking prompt (App Tracking Transparency)
- **The "Allow tracking" prompt is built but switched off**
  (`TrackingPermission.isEnabled = false`). The app has no ads or analytics SDK, so
  there is nothing to track and Apple does not allow asking. When ads or analytics are
  added: set the flag to `true`, check the purpose text `NSUserTrackingUsageDescription`
  in `ConnectSphere-Info.plist`, update the Privacy Policy and `LegalDocs.version`
  (server and app), and fill in the App Store privacy labels.
- Analytics is planned, not built: see [`ANALYTICS_PLAN.md`](ANALYTICS_PLAN.md).
