# Known Gaps — Deliberately Deferred

Scope decisions made during the 2026-08-20 QC audit fix pass that were deliberately
**not** implemented, with the reasoning, so they don't get rediscovered as "silent"
gaps later.

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
