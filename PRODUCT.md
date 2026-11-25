# ConnectSphere, Product

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
person*, someone who shares a niche hobby, or has a particular skill nearby,
means keyword search that only matches exact words.

## Who it's for

People aged **16 and up** (from high school on), since the app mixes a social
life with a first professional network. Sign-up is closed under 16 (the
birthday is self-declared; see [`KNOWN_GAPS.md`](KNOWN_GAPS.md)).

| Group | What they want | Example |
|---|---|---|
| **Students & new graduates (VN)** | A social life *and* a first professional network, without one leaking into the other | Linh, a 3rd-year Computing student: posts about J-pop with friends, and builds a Work profile for internships |
| **Young professionals** | Career networking and job search, separate from personal posts | Minh, a junior iOS developer: follows companies, connects with engineers, applies for jobs |
| **Hobby communities** | A place to gather around an interest, organise events, and buy/sell gear with people they trust | An anime fan community running watch-party events and a marketplace for figures |
| **Recruiters & companies** | A company page, job posts, and a way to find candidates by skill rather than keyword | A startup posting an iOS role and searching for "Swift developers in District 1" |

## What people do in it

Every account has two **modes**, Hobby and Work, switched from the top of the
feed. Most features exist in both, and content stays in the mode it was made in.

**Feed & posts**
- Write posts with photos/videos, hashtags, polls; privacy per post.
- Report a post, then optionally hide everything from its author without
  blocking them.
- Stories with highlights on the profile.
- Drafts and scheduled posts; save posts for later.
- Comments with photos and threaded replies; translate posts and comments.

**Profile**
- Cover photo, avatar, bio, location, highlights, an *About* section (Hobby).
- A Work profile with experience and skills, shown as a mini CV.
- Connections (friends) and follows, kept separately per mode; see and
  withdraw the requests you sent.

**Chat**
- Direct and group chats, with photos/videos, voice messages, replies,
  pinned messages, polls and message search; message requests from people you
  aren't connected to.
- **Meeting proposals** with a place, time and reminder (at the start, an hour
  before, or 7am on the day / days before; reminders already past can't be picked).
- Under your latest message: "Sending…", then "Sent", then the reader's photo
  once they've read it, updated live.
- A row of people at the top of Messages; long-press someone to hide them from
  the row (their chat stays). Unhide in Settings › Privacy › Hidden contacts.
- Centered notes when someone accepts your message request or changes the chat's
  theme or a nickname; they count as unread and show as the chat's preview.
- Share posts and communities into a chat; a floating chat bubble; chat *spaces*
  to group conversations.

**Communities**
- Join or create communities (Hobby mode only: a company's people already talk on
  Zalo, Viber or Slack, so Work mode has none; a community about a company lives in Hobby); a community page with cover,
  members and info.
- Post text, polls and events inside a community.
- A community post in the feed from a community you're not in has a Join pill
  beside its name (a long name is cut with "…" so the pill always shows), or
  Requested when the community approves members.
- Admin tools: post approval, a report queue, analytics, member roles.
- Per-member choice of new-post notifications (all / friends' posts / off),
  and "Manage your content" to see your own posts and comments there.

**Marketplace** (inside Communities)
- Sell with photos/videos, price, condition, description and a place picked on
  a map. One listing can hold **1–20 items**, each with its own title, price,
  condition, up to 6 photos and a **quantity** (1–999). The seller's caption is
  shown as written, never reformatted. Buyers pick which item to ask about.
- **Deposits and sales**: the seller records a buyer's deposit (units held for
  one of their chats), which comes off what others can buy. When the delivery
  arrives, the seller confirms that deposit as sold. Sales are final, and the
  sold count can't be typed in, only confirmed from deposits. Several buyers'
  deposits can be confirmed at once. A sold-out listing's card shows only
  "Sold" and its re-up count.
- **Reviews**: each seller's Marketplace page opens with a Reviews post. A
  confirmed sale sends that buyer a review card (valid 3 days): 0–5 stars and a
  comment. The seller can reply or report but not delete. A Legit badge shows at
  an average of 4.6 or more over at least 50 reviews.
- List it in the Marketplace and, optionally, in up to 5 of your communities,
  where it also appears as a post.
- Seller tools: an automatic first reply to buyers, hide the listing from your
  friends, mark as sold (after which buyers can no longer message about it).
- **Re-up**: a seller can re-up an item (by hand, or automatically every 1 / 3 / 7
  days at a chosen hour) so it shows as new. A re-up is a new post: likes and
  comments don't carry over, and the item shows how many times it was re-upped.
- **Seller profile**: selling stays apart from your personal life. A seller can
  set a Marketplace name, photo, cover and bio that show only on their listings
  and seller page (empty fields fall back to the normal profile). Tapping the
  seller on a listing opens the seller page, never the personal profile.
- **Follow a seller**: separate from friends and follows. Followers get a
  notification for each new listing (not re-ups) and see the seller's listings
  in their Home feed; the seller page shows the follower count.

**Jobs & companies**
- Company pages; job posts; a Jobs tab with recommendations, search and saved
  jobs; Easy Apply with applicant tracking; skill endorsements.
- **Only a verified HR posts jobs**, always for their own company, so job
  seekers can trust every offer. Becoming HR (Work mode › Settings): a code to a
  company-domain email (no Gmail), the tax code (MST), website and business
  registration PDF; the app admin checks them by hand (Admin tools › HR
  requests). One HR per tax code. A new HR's first 3 jobs are reviewed before
  they go live; every job carries a link to the company's own careers page;
  3 reports hide a job until the admin decides; revoking an HR removes their
  jobs and tells the applicants. HR shows as a ✓ "HR at Company" badge, in Work
  mode only. An HR posts from the **+** at the top of the Jobs tab
  (For you and Search), which opens the composer on Job.
- A job's place is a **ward**, required unless the job is remote. "Near you" means within 10 km
  straight-line, ward centre to ward centre, never a shared city name (Thạnh Mỹ
  Tây and Vũng Tàu are both "Ho Chi Minh City" but ~65 km apart). Cards show
  "~N km"; Search filters "Within 5–30 km". Pay can be "Negotiable".
- An HR can attach the company's job description (PDF); applicants read it
  full screen. Applicants keep a CV (PDF) on their Work profile: Easy Apply
  attaches it, and only verified HRs can open it.
- A Work post can be marked **Open to work**; on those posts a verified HR
  can reply with one of their open jobs, which shows as a job card.

**Search & assistant**
- **AI search** over people and posts in plain language (see below).
- An in-app assistant (Settings or Messages): answers how-to questions about
  the app in English or Vietnamese, changes safe settings (light/dark, theme
  colour, app icon, language, translations, search radius, message sounds,
  AI suggestions) with Undo, and opens any setting with the row highlighted.
  Privacy and security settings are only explained and opened, never changed;
  chat settings (mute, nickname, chat theme) are only explained.

**Account & safety**
- Sign in (incl. Google), email verification, two-factor authentication. The
  2FA step shows only the code boxes (no Google button); Resend clears and
  refocuses them, and every code email has the code at the start of its subject
  so a resent one never hides in the earlier thread.
- Saved accounts on the device for quick switching, sign in with email or
  `@username`.
- Change your `@username` once every 6 months (Manage account › Username);
  the server enforces it, and an old username is never handed to someone else.
- Blocked users, muted words, activity log, recently deleted, lock profile,
  privacy and security settings, links open in an in-app browser.
- English / Vietnamese, light/dark themes.
- Reports go to the app admin, who can keep, remove, restrict (for a number of
  days) or ban. A restricted account can browse and message friends, but can't
  post, comment, join communities, sell or add friends, and sees a banner saying
  until when. The admin also reviews the interests people suggest for the
  picker (Admin tools › Interest suggestions).

## What makes it different

1. **Hobby and Work in one app, kept apart.** One account, two personas: each
   mode has its own feed and its own connections (communities are Hobby-only), so
   friends and colleagues each see the side that's meant for them.
2. **AI search that understands what you mean.** Ask "iOS developers near
   Landmark 81 who like J-pop" in Vietnamese or English; a local LLM works out
   the intent and the place, and vector search (pgvector) finds matching people
   and posts, not just exact keywords. Runs locally (Ollama), so queries don't
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

Rules the app already follows. Keep them when adding features:

- **Privacy by mode.** Content and connections never cross from Hobby to Work
  (or back) unless the user moves them.
- **Never lose someone's work by surprise.** Every form asks before Cancel
  discards it, even when empty, and swipe-to-dismiss can't skip the question.
- **Ask before anything that can't be undone**. Delete, mark as sold, leave
  a community.
- **The right input for the job.** Number fields open the number keypad;
  location fields search places (Apple Maps) as you type.
- **Bilingual by default.** Every string ships in both
  `en.lproj` and `vi.lproj`.
- **Strip personal metadata.** Photos and videos lose GPS and camera data
  before upload.
- **Pop-ups are for a quick look.** A sheet loads fresh each time it opens and
  has no pull-to-refresh: pulling down closes it. Full pages refresh.

## Not yet / out of scope

Summarised from [`KNOWN_GAPS.md`](KNOWN_GAPS.md):

- **Dating and partner-finding.** ConnectSphere is for finding friends and
  colleagues; people looking for a partner are better served by a dating app.
  A Dating space was built and then archived (`legacy/dating/`, kept outside the repository).
- **Push notifications** while the app is closed (in-app notifications work).
- Chat "delivered" receipts are best-effort (read receipts work).
- No list of your *sent* connection requests yet.
- Some performance and design-system clean-up deferred past the project.

## Glossary

| Term | Meaning |
|---|---|
| **Mode** | Hobby or Work. The side of the app you're using; content belongs to one mode |
| **Persona** | Your profile for one mode (Hobby profile, Work profile) |
| **Connection** | A mutual friend link in one mode; separate from following |
| **Community** | A group around a hobby (fandom); Hobby mode only |
| **Listing** | An item for sale in the Marketplace |
| **Community link** | A listing also shown as a post in a community (up to 5) |
| **Highlight** | A saved collection of stories on a profile |
| **Space** | A folder that groups chat conversations |
| **Meeting proposal** | A chat message proposing a time and place to meet, with a reminder |
| **Official account** | `@connectsphere`, with the seal badge: announces new features and is the app's only admin. Can't be reported, blocked or deleted |
| **Whale** | The app's word for a like, after the whale mascot: tap the whale to whale a post or comment ("Kujira whaled your post"). It is grey until you whale, then takes your theme colour |
