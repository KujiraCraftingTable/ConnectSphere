# Feed ranking review, Facebook, TikTok and ConnectSphere

> How the two big feeds decide what to show, how our Home feed ("For you")
> does it today, where ours falls short, and a TikTok-style plan to fix it.
> Written October 2026. Our side reflects the code at that time
> (`server/Sources/App/Stores/FeedStore.swift`).

Sources (summarised in our own words):

- Meta, *Our Approach to Facebook Feed Ranking* (updated June 2025),
  <https://transparency.meta.com/features/ranking-and-content/>
- TikTok, *How TikTok recommends content*,
  <https://www.tiktok.com/support/faq_detail?id=7655285288050104852&category=web_account>

---

## 1. How Facebook ranks Feed

**Pipeline.** For posts from people, Groups and Pages you're connected to,
ranking runs in four steps:

1. **Inventory**, every post you could see right now.
2. **Signals**, thousands of facts about you, the post, and you *and* the post.
3. **Predictions**, over 100 models each guess how you'll react.
4. **Score**, the predictions are combined into one relevance score and the
   feed is sorted by it.

Recommended posts from people you don't know, then ads, are mixed in afterwards.

**Signals.** Three groups:

| About you | About the post | About you *and* the post |
|---|---|---|
| How many friends / Pages / Groups you have, how often you interact with each friend, how many new posts are waiting | Who made it and who shared it, how many people viewed it, **average time spent viewing it**, total likes and comments, and the **ratio of clicks / likes / comments to views** | How you've interacted with this post and **similar posts**, your relationship to the author, **how much you've viewed and interacted with this author before** |

**Predictions.** The most-used models predict whether you will:

- click on some part of the post, or like, react to or comment on it;
- share it, or interact with it meaningfully (comments, shares, sending it, time spent);
- **spend time viewing it** rather than scroll past, or spend time in its comments;
- watch its video, and for how long;
- want to see **more or less** from that person or Page.

Some predictions push posts *down*: how likely you are to hide, snooze,
unfollow or report it, and "angry" reactions.

Two points matter for us. Meta says no single prediction is enough, since it's
the *combination* that ranks well. And the weighting is personal: for
someone who never presses Like, **time spent reading** says more than likes.

**Controls.** Favorites, Snooze and Unfollow; **Interested / Not interested**,
which temporarily raises or lowers that post *and posts like it*; and a
chronological "Feeds" tab.

## 2. How TikTok ranks For You

**Starting out.** At sign-up you can pick interest categories (pets, travel…).
If you skip, you're shown recent content that's popular with a broad audience,
matched to your language and location, plus popular creators to follow.

**Three kinds of factors.**

- **What you do:** likes, shares, comments, follows, and above all **whether
  you watch a video to the end or skip it** (time spent watching).
- **What the content is:** sounds, hashtags, number of views, the country it
  was posted in.
- **Who you are:** language, location, time zone and day, device.

For most people, **what you do outweighs everything else**, and watch time is
the strongest part of it.

**"People like you".** Some recommenders use other people with similar
taste: if A liked videos 1–3 and B liked 1–5, A will probably like 4 and 5
(collaborative filtering).

**Diversity on purpose.**
- New creators and topics are mixed in, even ones that don't match your known
  interests, so the feed doesn't narrow.
- It **doesn't show videos you've already seen**.
- It **doesn't show two posts in a row from the same creator**.
- It deliberately breaks up runs of one kind of content that would be harmful
  in bulk (for example extreme dieting).

**Controls.** Like, **Not interested** ("less like this"), refresh your feed,
manage topics, filter keywords (optionally with similar words), and turn
personalisation off.

**Why it works.** TikTok gets a strong, honest signal from every single item
you see (did you finish it or skip it), learns your dislikes as well as your
likes, never repeats itself, keeps mixing in something new, and borrows taste
from people like you. That's why it finds "the right video for the right
person" so fast.

## 3. How ConnectSphere ranks the Home feed today

Code: `FeedStore.getRecommendedFeed` (`server/Sources/App/Stores/FeedStore.swift`),
served by `GET /api/feed/recommendations`.

**Candidates.** Posted posts in the current mode (Hobby or Work), excluding:
- your own posts and Marketplace listings;
- hidden posts, blocked users, muted communities and muted words;
- posts you're not allowed to see (privacy, private or community-only posts).

**Your taste** (`buildTasteVector`) is one embedding vector:
- 0.6 × your **profile** (bio, interests, skills, job… embedded);
- 0.4 × the average of the posts behind your **last 20 likes**.

**Score**

```
score = 0.50 × semantic      cosine similarity of the post to your taste
      + 0.35 × recency       e^(−age_hours / 72)
      + 0.15 × engagement    log(1 + likes + 2·comments) / log(501), capped at 1
      + 0.15  if the author is one of your connections
```

**Two passes.** First, only posts from connections or with similarity ≥ 0.65.
If that doesn't fill a page (20), it tops up from everything, ranked by the
same score. Pages are keyset-paginated, with "now" frozen at the first page so
the order stays stable.

## 4. Side by side

| | Facebook | TikTok | ConnectSphere |
|---|---|---|---|
| Learns from likes | ✅ | ✅ | ✅ (last 20) |
| Learns from comments / shares / saves | ✅ | ✅ | ❌ |
| **Time spent viewing / skip** | ✅ (strong) | ✅ (**strongest**) | ❌ not recorded |
| Opened / clicked into a post | ✅ | ✅ | ❌ |
| "Less like this" | ✅ Not interested (similar posts too) | ✅ Not interested | ❌ Hide removes one post only |
| Doesn't repeat what you've seen | ✅ (new posts counted) | ✅ | ❌ no record of what was shown |
| Several interests at once | ✅ (many models) | ✅ | ❌ one averaged vector |
| Closeness to each person | ✅ per friend / Page / Group | ✅ profile visits, follows | ⚠️ flat +0.15 for any connection; follows ignored |
| Popularity measure | ✅ rate per view | ✅ views & completion | ⚠️ raw lifetime totals |
| Diversity (author / topic) | ✅ | ✅ no same creator twice in a row | ❌ |
| Deliberate exploration | ✅ recommended content mixed in | ✅ new creators/topics | ⚠️ only as a fallback when matches run out |
| "People like you" | ✅ | ✅ collaborative filtering | ❌ |
| Cold start | ✅ | ✅ interest picks → popular by language/area | ⚠️ profile embedding only; else recency + popularity |
| User controls | Favorites, snooze, interested, chronological | Not interested, refresh, topics, keyword filter | Hide, mute words, mute community |

## 5. Where ours is weak

| # | Weakness | Effect | Severity |
|---|---|---|---|
| 1 | **Only likes teach it.** No reading time, opens, comments, saves or shares | Most people rarely press Like, so the feed learns almost nothing about them; TikTok's strongest signal is missing entirely | 🔴 High |
| 2 | **No "less like this".** Hide removes one post | It can't learn what you dislike; similar posts keep coming | 🔴 High |
| 3 | **No record of what was shown** | Every refresh shows the same top posts; the feed feels stale | 🔴 High |
| 4 | **One averaged taste** | Someone into J-pop *and* iOS gets a blurry middle that matches neither well | 🟠 Medium |
| 5 | **Flat connection boost** | A close friend and someone you never talk to count the same; people you follow get nothing | 🟠 Medium |
| 6 | **Popularity as raw totals** | Old posts with many likes beat fresh posts doing well for how often they've been seen | 🟠 Medium |
| 7 | **No diversity rules** | One busy author or one topic can fill the screen | 🟠 Medium |
| 8 | **No "people like you"** | Misses good posts that don't look similar in text but are loved by similar people | 🟡 Lower |
| 9 | **Weak cold start** | A new user with an empty profile sees recency + popularity only | 🟡 Lower |
| 10 | **No planned exploration** | Taste narrows over time; new topics appear only when matches run out | 🟡 Lower |

**Bottom line:** the ranking *formula* is reasonable, but it is fed by one thin
signal (recent likes) and has no memory of what it showed or what you skipped.
Facebook and TikTok both rank mainly on **behaviour** (what you look at, finish,
skip and say "not interested" to), and TikTok also forces variety. That gap,
not the formula, is why our feed is weaker.

## 6. Upgrade plan (TikTok-style)

Each phase can ship and be checked on its own.

**Phase A, Record what people actually do.**
- **Table:** a `post_impressions` table, one row per user × post: first/last
  seen, total time on screen, opened, skipped fast (< 1 s). Rows older than 90
  days are cleaned up daily.
- **App:** the app measures how long each feed post is at least half on screen
  and sends small batches to `POST /api/feed/impressions` (post ids and times
  only).

**Phase B, Rank on behaviour.**
- **Taste from everything you do,** recent actions counting more (14-day
  half-life):
  - like ×1, comment ×2, save ×2, share ×3;
  - open ×1, long read (≥ 8 s) ×1.5;
  - fast skip ×−0.5.
- **Already seen:** posts seen in the last 3 days drop out, and older-seen
  posts are pushed down.
- **Popularity as a rate:** `(likes + 2·comments + 3·shares) / (views + 20)`.

**Phase C, "Not interested" that learns.**
- A **Not interested** option pushes down posts similar to that one, and that
  author's posts, for 30 days.
- **Show more like this** does the opposite.

**Phase D, Several tastes, closeness, diversity.**
- **Several tastes:** up to 4 taste clusters per person; each post scores
  against the best one.
- **Closeness:** a per-author score from your likes, comments, messages and
  views in the last 60 days, replacing the flat +0.15, with follows included.
- **Diversity:** never the same author twice in a row, at most 2 per author and
  3 per topic per 10 posts, and at least 1 in 10 posts from something new.

**Phase E, "People like you" and cold start.**
- **People like you:** boost posts liked or read long by users who liked the
  same posts as you in the last 30 days.
- **Cold start:** new accounts' interest picks seed the first taste directly;
  with nothing at all, show what's popular in their language and area this
  week.

**Measuring progress.** From the impressions data, track average reading time
per shown post and the share of shown posts that get any action, before and
after each phase.
