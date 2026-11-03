# ConnectSphere — Product

> One account, two sides of your life. ConnectSphere is a social app for
> Vietnam where your **Hobby** side (friends, interests, fandoms) and your
> **Work** side (career, colleagues, jobs) live in the same app but never mix.

This file says *what* the app is for and *who* it's for. For *how* it's built,
see [`README.md`](README.md) and [`ARCHITECTURE.md`](ARCHITECTURE.md); for what
is deliberately unfinished, see [`KNOWN_GAPS.md`](KNOWN_GAPS.md).

---

## The problem

A young person in Vietnam today spreads their social life across several apps:

- **Facebook / Zalo** for friends, family and interest groups;
- **LinkedIn** (often half-empty) for their career;
- **buy-and-sell groups** scattered across Facebook for second-hand items.

Two things go wrong. Friends and colleagues see the same profile, so people
either over-share at work or under-share with friends. And finding *the right
person* — someone who shares a niche hobby, or has a particular skill nearby —
means keyword search that only matches exact words.

## Who it's for

People aged **16 and up** (from high school on), since the app mixes a social
life with a first professional network. Younger people can still use it, but
Dating, a separate space kept out of normal search, is locked under 16.

| Group | What they want | Example |
|---|---|---|
| **Students & new graduates (VN)** | A social life *and* a first professional network, without one leaking into the other | Linh, a 3rd-year Computing student: posts about J-pop with friends, and builds a Work profile for internships |
| **Young professionals** | Career networking, job search and work communities, separate from personal posts | Minh, a junior iOS developer: follows companies, joins a Swift community, applies for jobs |
| **Hobby communities** | A place to gather around an interest, organise events, and buy/sell gear with people they trust | An anime fan community running watch-party events and a marketplace for figures |
| **Recruiters & companies** | A company page, job posts, and a way to find candidates by skill rather than keyword | A startup posting an iOS role and searching for "Swift developers in District 1" |

## What people do in it

Every account has two **modes**, Hobby and Work, switched from the top of the
feed. Most features exist in both, and content stays in the mode it was made in.

**Feed & posts**
- Write posts with photos/videos, hashtags, polls; privacy per post.
- Stories with highlights on the profile.
- Drafts and scheduled posts; save posts for later.
- Comments with photos and threaded replies; translate posts and comments.

**Profile**
- Cover photo, avatar, bio, location, highlights, an *About* section (Hobby).
- A Work profile with experience and skills, shown as a mini CV.
- Connections (friends) and follows, kept separately per mode.

**Chat**
- Direct and group chats, with photos/videos, voice messages, replies,
  pinned messages, polls and message search.
- **Meeting proposals** with a place, time and reminder.
- Share posts and communities into a chat; a floating chat bubble; chat *spaces*
  to group conversations.

**Communities**
- Join or create communities (hobby or work); a community page with cover,
  members and info.
- Post text, polls, events and jobs inside a community.
- Admin tools: post approval, moderation, analytics, member roles.
- Per-member choice of new-post notifications (all / friends' posts / off),
  and "Manage your content" to see your own posts and comments there.

**Marketplace** (inside Communities)
- Sell an item with photos/videos, price, condition, description and a place
  picked on a map.
- List it in the Marketplace and, optionally, in up to 5 of your communities,
  where it also appears as a post.
- Seller tools: an automatic first reply to buyers, hide the listing from your
  friends, mark as sold (after which buyers can no longer message about it).

**Jobs & companies**
- Company pages; job posts; browse and filter jobs; apply with a note.

**Search & assistant**
- **AI search** over people and posts in plain language (see below).
- An in-app assistant chat.

**Account & safety**
- Sign in (incl. Google), email verification, two-factor authentication.
- Blocked users, muted words, activity log, recently deleted, privacy settings.
- English / Vietnamese, light/dark themes.

## What makes it different

1. **Hobby and Work in one app, kept apart.** One account, two personas: each
   mode has its own feed, its own connections and its own communities, so
   friends and colleagues each see the side that's meant for them.
2. **AI search that understands what you mean.** Ask "iOS developers near
   Landmark 81 who like J-pop" in Vietnamese or English; a local LLM works out
   the intent and the place, and vector search (pgvector) finds matching people
   and posts — not just exact keywords. Runs locally (Ollama), so queries don't
   leave the server. Details: [`AI_SEARCH_OVERVIEW.md`](AI_SEARCH_OVERVIEW.md); its gaps
   next to Spotify, Netflix and Amazon: [`AI_SEARCH_REVIEW.md`](AI_SEARCH_REVIEW.md).
   How the Home feed ranks posts, and its gaps next to Facebook and TikTok:
   [`FEED_RANKING_REVIEW.md`](FEED_RANKING_REVIEW.md).
3. **Communities with a Marketplace built in.** Buying and selling happens
   among people who share an interest; a listing can appear in the communities
   it's relevant to, with seller protections (auto-reply, hide from friends,
   no messages after it's sold).
4. **Built for Vietnam first.** Every screen in Vietnamese and English,
   switchable in the app; places come from Apple Maps search, tuned for
   Vietnamese locations.

## Product principles

Rules the app already follows — keep them when adding features:

- **Privacy by mode.** Content and connections never cross from Hobby to Work
  (or back) unless the user moves them.
- **Never lose someone's work by surprise.** Every form asks before Cancel
  discards it, even when empty, and swipe-to-dismiss can't skip the question.
- **Ask before anything that can't be undone** — delete, mark as sold, leave
  a community.
- **The right input for the job.** Number fields open the number keypad;
  location fields search places (Apple Maps) as you type.
- **Bilingual by default.** Every string ships in both
  `en.lproj` and `vi.lproj`.
- **Strip personal metadata.** Photos and videos lose GPS and camera data
  before upload.

## Not yet / out of scope

Summarised from [`KNOWN_GAPS.md`](KNOWN_GAPS.md):

- **Push notifications** while the app is closed (in-app notifications work).
- Chat "delivered" receipts are best-effort (read receipts work).
- No list of your *sent* connection requests yet.
- A structured ward/commune address picker exists but isn't wired in.
- Some performance and design-system clean-up deferred past the project.

## Glossary

| Term | Meaning |
|---|---|
| **Mode** | Hobby or Work — the side of the app you're using; content belongs to one mode |
| **Persona** | Your profile for one mode (Hobby profile, Work profile) |
| **Connection** | A mutual friend link in one mode; separate from following |
| **Community** | A group around a hobby (fandom) or a field of work |
| **Listing** | An item for sale in the Marketplace |
| **Community link** | A listing also shown as a post in a community (up to 5) |
| **Highlight** | A saved collection of stories on a profile |
| **Space** | A folder that groups chat conversations |
| **Meeting proposal** | A chat message proposing a time and place to meet, with a reminder |
