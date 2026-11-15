# ConnectSphere architecture

ConnectSphere is a native iOS app (SwiftUI) backed by a Swift/Vapor 4 API over
PostgreSQL + pgvector, with Redis for background jobs and a local Ollama model
for the AI search pipeline. This document describes how the code is layered
and the rules that keep it that way.

## iOS app: MVVM

Every screen follows **Model–View–ViewModel**. A view describes the screen; a
ViewModel holds the screen's state and does its work; repositories talk to
the server.

| Layer | Lives in | Owns | Must not |
|---|---|---|---|
| **View** (SwiftUI `struct … : View`) | `Features/<Feature>/Views/`, `Core/Components/`, `Core/UI/` | Layout, bindings to its ViewModel, presentation state (sheet / alert / dialog flags, focus, animation), navigation | Call a repository, `NetworkClient`, `AuthService` or `KeychainHelper`; hold loading/error state; build user-facing error text |
| **ViewModel** (`@MainActor @Observable final class …ViewModel`) | `Features/<Feature>/ViewModels/`, `Core/ViewModels/` | Screen state, async calls, loading and error state, user-friendly error messages (`Bundle.app.loc`), validation, optimistic updates and rollback, cross-screen broadcasts | Know about layout or SwiftUI view types |
| **Repository / Service** | `Features/<Feature>/Repository/`, `Core/Auth/`, `Core/Network/` | One method per API call, request building, decoding, the offline cache | Hold UI state |
| **Model** | `Features/<Feature>/Models/`, `Core/Network/DTOs/` | Plain data: DTOs decoded from the API, and app models such as `Post` | Behaviour beyond simple computed properties |
| **`AppState`** (`Core/AppState.swift`) | One instance, in the SwiftUI environment | App-wide session: auth token, current user, Hobby/Work mode, badge counts | Screen-specific state |

The app has about **73 ViewModels** and **25 repositories**. No view calls the
network or the Keychain directly; a single `grep` over the view folders
proves it (see *Checking the rule* below).

### How the pieces connect

```mermaid
flowchart LR
    subgraph iOS app
        V[View<br/>SwiftUI] -- "binds to / calls" --> VM[ViewModel<br/>@Observable]
        VM -- "async calls" --> R[Repository]
        R --> NC[NetworkClient<br/>HTTP + JSON]
        R -. "best-effort" .-> C[(CacheStore<br/>SwiftData)]
        VM <-- "session, mode, badges" --> AS[AppState]
        V -- "reads" --> AS
        VM -- "postUpdated / postDeleted …" --> N((NotificationCenter))
        N -- "keeps other lists in step" --> VM
        WS[WebSocketClient] -- "realtime events" --> VM
    end
    NC -- "REST /api/…" --> API[Vapor API]
    WS -- "Socket.IO" --> API
    API --> DB[(PostgreSQL<br/>+ pgvector)]
    API --> Q[(Redis<br/>job queue)]
    API --> O[Ollama<br/>local LLM]
```

### Example: tapping Like on a post

1. **View**: `PostCard`'s like button calls
   `Task { await actions.toggleLike(postId: post.id) }`.
   `actions` is the card's own `PostActionsViewModel`.
2. **ViewModel**: `PostActionsViewModel.toggleLike` flips `isLiked` and
   `likeCount` straight away (optimistic), so the thumb fills instantly.
3. **Repository**: `PostRepository.toggleLike` builds the request, and
   `NetworkClient` sends `POST /api/posts/:id/like` with the user's token.
4. **Server**: `InteractionsController.likePost` toggles the row in
   `post_likes`, updates `posts.like_count` in one transaction, and queues
   the "liked your post" notification.
5. **ViewModel**: it then reconciles with the server's answer, or restores
   the previous state if the request failed.
6. **View**: SwiftUI re-renders the card from the ViewModel's new state.
   The view itself never saw a request or an error.

### Keeping screens in step

The same post can be on screen in several places (feed, profile, saved list,
detail). A ViewModel that changes a post broadcasts it on `NotificationCenter`
(`.postUpdated`, `.postDeleted`, `.postRestored`, `.postCreated`), and every
list ViewModel showing that post patches itself. Hobby and Work are separate
datasets everywhere: lists, search and stories are always loaded for the
current mode.

### Realtime and caching

- **`WebSocketClient`** (Socket.IO) delivers chat messages, typing, read
  receipts (`messages_read`), chat notes (`conversation_event`,
  `message_request_accepted`), notification counts, and so on. ViewModels register and unregister their
  listeners, for example `FeedViewModel.startChatBadge` and
  `NotificationBadgeViewModel.startRealtime`.
- **`CacheStore`** keeps raw response bodies in SwiftData so a screen can
  show its last data offline. It is best-effort: the app works without it.

### Adding a new screen

1. **Model:** add the DTO/model under `Features/<Feature>/Models` or
   `Core/Network/DTOs`.
2. **Repository:** add a repository method per endpoint.
3. **ViewModel:** create `Features/<Feature>/ViewModels/<Name>ViewModel.swift`.
   - Declare it `@MainActor @Observable final class`.
   - It holds state, calls the repository, maps errors with
     `friendlyError(_:)` or `Bundle.app.loc(...)`, and returns results the
     view needs for navigation (e.g. `Bool`, or the created object).
4. **View:** create `Features/<Feature>/Views/<Name>View.swift`.
   - It owns the ViewModel as `@State private var viewModel = …`, or
     `State(initialValue:)` when it needs init arguments.
   - It binds controls with `$viewModel.field`.
   - It keeps only presentation state.
5. **Strings:** put every user-facing string in both `en.lproj` and
   `vi.lproj` `Localizable.strings`.
6. **Tests:** test the ViewModel's pure logic (validation, state machines)
   with Swift Testing in `ConnectSphereTests/`.

### Checking the rule

This must print nothing:

```sh
grep -rlE ": View \{|: View, " --include="*.swift" ConnectSphere \
  | xargs grep -lE "Repository\(\)|repository\.|NetworkClient|AuthService\.shared|KeychainHelper" \
  | grep -v "/ViewModels/\|/Repository/"
```

## Backend: layered Vapor API

The server has no views (it returns JSON), so MVVM does not apply. It is
layered instead:

| Layer | Lives in (`server/Sources/App/`) | Role |
|---|---|---|
| **Routes + Controllers** | `routes.swift`, `Controllers/` | Decode and validate input (enums against allowlists, lengths bounded), check auth (`req.userID` from `AuthMiddleware`), call stores/services, shape the JSON |
| **Services** | `Services/`, `AI/` | Multi-step business logic: notifications (`NotifyService`), posting, the AI search pipeline, embeddings (`ChunkService`), ranking |
| **Stores** | `Stores/` | Parameterised SQL through SQLKit (`\(bind:)`, `\(uuid:)`); no Fluent ORM |
| **Jobs** | `Jobs/` | Background work on Redis via Vapor Queues (only when `RUN_JOBS=1`): tag extraction, chunk embedding and its 30-minute sweep, social notifications, translation, scheduled-post publishing, auto re-up, meeting reminders, daily housekeeping |
| **Realtime** | `Realtime/` | The Socket.IO-compatible hub the app's `WebSocketClient` talks to |
| **Infra** | `Infra/` | Environment, error middleware (`{ status, code, message }`), rate limiting, security headers, the migration runner (`RUN_MIGRATIONS=1`), upload metadata stripping |
| **Commands** | `Commands/` | One-off maintenance commands: `seed-demo`, `strip-upload-metadata`, `verify-company`, `community-reports`, `moderator`, `moderation`, `moderation-eval`, `official-account` |
| **Moderation** | `Moderation/` | Reports, cases, decisions, strikes and appeals (migration 089): `ModerationPolicy` (the shared rule list), `ModerationStore`/`ModerationQueue` (SQL), `ModerationService` (decisions), `ModerationNotices` |

The database schema lives in `backend/migrations/` (147 files, `001`–`148`) and is replayed at boot when `RUN_MIGRATIONS=1`.
The AI search design is described in `AI_SEARCH_OVERVIEW.md`.
