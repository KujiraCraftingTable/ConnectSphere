# Analytics plan

Status: **plan only, nothing is built.** The App Tracking Transparency prompt is
built but switched off (`TrackingPermission.isEnabled = false`, see `KNOWN_GAPS.md`).
This file is the starting point for the analytics work.

## 1. Does analytics need the tracking prompt?

Apple calls it "tracking" only when the app's data is linked with other companies'
data (for targeted ads or ad measurement) or shared with data brokers.

- **Events kept on our own server** (Vapor + Postgres) and used only to improve the
  app are **not tracking**. The prompt stays off; the data is declared in the App Store
  privacy labels instead.
- **Third-party SDKs** can count as tracking (Firebase with ad features, Meta,
  AppsFlyer and similar). Then the prompt is needed.

**Decision to make:** log events into our own database (recommended: fits the stack,
keeps student data in-house, no prompt). Alternative: self-hosted PostHog for ready-made
dashboards.

## 2. What to track

### Fields on every event

| Field | Why |
|---|---|
| `user_id` (or an anonymous id before sign-in) | Follow one person over time without storing their name. |
| `session_id` | Group the actions of one visit. |
| `mode` (`hobby` / `work`) | The two modes are separate datasets, so every number is split by mode. |
| `app_version`, `locale` (vi/en), `device_model` | See which release, language or device a problem appears in. |
| `timestamp` (server time) | Phone clocks can be wrong. |

Event names are `object_action`, for example `post_published`, `search_submitted`.

### A. Sign-up and onboarding (does a new student make it in?)
- `signup_started`, `signup_completed`, `onboarding_step_completed` with a step number:
  shows the step people quit on.
- Sign-in method (password or Google): which one to invest in.
- **Activation**, for example within 7 days: onboarding finished, 1 connection made,
  1 post or comment. The best early sign that someone will stay.

### B. Return visits (do they come back?)
- Daily, weekly and monthly active users, and **D1 / D7 / D30 retention** (the share of
  new users still active after 1, 7 and 30 days). Retention says more than raw traffic.
- **Mode share:** time in Hobby versus Work and how often people switch. Shows whether
  the hybrid idea in `PRODUCT.md` works.

### C. Feature funnels (where does each feature lose people?)
- **Posting:** composer opened, then post published (also draft, scheduled, abandoned).
- **Feed:** posts seen versus posts interacted with (like, comment, share), time on a
  post, "hide" and "see fewer" taps. Shows whether the ranking is good.
- **AI search:** `search_submitted`, results count, zero-result rate, tapped result
  position, search duration. Zero-result and low-tap searches show where it fails.
- **People you may know:** suggestion shown, connection request, accepted.
- **Communities:** join requested, approved, first post in the community.
- **Marketplace:** listing created, buyer started a chat, marked sold, re-up usage.
- **Jobs (Work mode):** job viewed, Easy Apply started, submitted.
- **Chat:** counts only (messages per day, requests accepted). Never message content.
- **Translation:** how often the EN/VI swap is used.

### D. Quality and speed
- App start time, feed load time, API latency and error rate per screen.
- Crashes: Apple's MetricKit and Xcode Organizer, free, no SDK.

### E. Safety
- Reports per 1,000 posts and time from report to action. Decree 147 expects takedown
  within 24h / 48h, so this shows we meet it.

### Main number
**Weekly active students with at least one meaningful interaction** (a comment, a
message or a new connection). It reflects real value, not just app opens.

## 3. What not to track
- Message content, photos, exact GPS location, birthdays, contacts, typed text,
  passwords or tokens.
- AI search query text: keep it a short time (for example 30 days), then keep counts only.
- Users are 16 and older, many of them 16 to 17: collect the minimum.

## 4. Legal side (Vietnam Law 91/2025 and Decree 356/2025)
- Behaviour tracking counts as sensitive data: ask for consent **separately**, with an
  **Analytics on/off switch** in Settings, not hidden in the Terms. Whether it may default
  to on for "improving the app" is a question for a lawyer; the safe choice is to ask.
- Update the Privacy Policy and bump `LegalDocs.version` (server and app) so everyone
  agrees again.
- Include analytics data in account deletion and in the data export.
- Retention: raw events about 12 months, then only totals (add a job in
  `BackgroundJobs.swift`).
- App Store privacy labels: declare "Product Interaction" under Analytics.

## 5. Suggested phases
1. **Foundation:** an `analytics_events` table, one `POST /api/events` endpoint that
   saves batches, an `AnalyticsService` on iOS that queues and batches events, and the
   consent switch.
2. **First 10 events:** signup completed, onboarding step, session start, mode switch,
   post published, search submitted, search result tapped, connection sent, listing
   created, job applied.
3. **Dashboards:** activation, D1 / D7 / D30 retention, the funnels above and AI search
   zero-result rate, each split by mode.
4. **Later:** crash and performance metrics, safety metrics.

## 6. If a third-party SDK is added later
Set `TrackingPermission.isEnabled = true`, check the purpose text
`NSUserTrackingUsageDescription` in `ConnectSphere-Info.plist`, and fill in the App Store
privacy labels.
