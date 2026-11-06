# AI search review, Spotify, Netflix, Amazon and ConnectSphere

> How prompt-style ("describe what you want") search works at Spotify, Netflix
> and Amazon, how our AI people search does it today, where ours falls short,
> and a plan to close the gap so people find the friends who fit **them**.
> Written October 2026. Our side reflects the code at that time
> (`server/Sources/App/Controllers/SearchController.swift`,
> `server/Sources/App/AI/SearchStore.swift`, `server/Sources/App/AI/OllamaService.swift`);
> the pipeline itself is described in [`AI_SEARCH_OVERVIEW.md`](AI_SEARCH_OVERVIEW.md).

Sources (summarised in our own words):

- Manali Somani, *Smarter Searches with Vector Search: How It Works and Why It Matters*,
  <https://manalisomani099.medium.com/smarter-searches-with-vector-search-how-it-works-and-why-it-matters-64175c450e55>
- Google Cloud Tech, *Give your app search superpowers: Agent Retrieval (Vector Search 2.0)*,
  <https://www.youtube.com/watch?v=-L5khDHrQSE>, and the post it links: Kaz Sato,
  *Introducing Vertex AI Vector Search 2.0*,
  <https://medium.com/google-cloud/introducing-vertex-ai-vector-search-2-0-from-zero-to-billion-scale-90ed666dac43>
- Spotify Engineering, *Introducing Natural Language Search for Podcast Episodes*,
  <https://engineering.atspotify.com/introducing-natural-language-search-for-podcast-episodes/>;
  TechCrunch on AI Playlist (2024) and Prompted Playlist (2025),
  <https://techcrunch.com/2024/04/07/spotify-launches-personalized-ai-playlists-you-can-build-using-prompts/>,
  <https://techcrunch.com/2025/12/10/spotify-tests-more-personalized-ai-powered-prompted-playlists/>
- Netflix Help Center, *How Netflix's Recommendations System Works*,
  <https://help.netflix.com/en/node/100639>; TVBEurope on the 2025 natural-language search test,
  <https://www.tvbeurope.com/artificial-intelligence/netflix-tests-natural-language-ai-search-engine>
- Nigam et al., *Semantic Product Search* (Amazon, KDD 2019),
  <https://www.amazon.science/publications/semantic-product-search>

---

## 1. What the two references teach

**The basics (Somani).** Turn every item and every query into an embedding with
the same model, compare them by cosine similarity, and return the closest. That
is what lets "buy a smartphone" find "purchase a mobile phone": meaning, not
spelling, decides the match. The same machinery powers search *and*
recommendations.

**What production adds (Sato / Google).** Four lessons:

1. **Hybrid search.** Semantic search finds "board shorts" for "men's outfit for
   the beach", but misses codes, names and brand-new words the embedding model
   never learned. Keyword search catches exactly those. Run both and merge the two
   ranked lists with **Reciprocal Rank Fusion (RRF)**. Each result scores
   Σ 1 / (k + its rank in each list).
2. **Embed questions and answers differently** ("task types"). A question and its
   answer aren't naturally similar; models trained for this asymmetry match them
   better. Google cites a 30–40 % quality gain for its own model.
3. **Filters combine with meaning**, "casual summer wear, Shorts, under $50".
4. **Vectors stay in sync** with the data automatically.

The flow in the screenshot that started this review, *prompt → vector →
pgvector cosine search → inject context → LLM writes the answer*. Adds a fifth:
the system **explains** what it found.

## 2. How the big three do prompt search

**Spotify.**
- *Podcast search* uses **dense retrieval**: a model trained so queries and
  episodes land close together in one space. "Electric cars climate impact"
  finds episodes about "environmental impact of electric vehicles". It was
  added **next to** keyword search, not instead of it.
- *AI Playlist / Prompted Playlist*: an LLM reads "sad rainy-day acoustic", then
  **your listening history** picks and orders the tracks. Two people typing the
  same prompt get different playlists. You **refine** it ("less upbeat", "more
  pop") instead of starting over.

**Netflix.**
- Ranking always starts from **your taste**: what you watched, and what members
  with similar taste watched. Search is ranked the same way, so a short, vague
  query is read in light of who you are.
- A search that finds nothing still **recommends alternatives**.
- In 2025 it began testing natural-language "mood" search ("something sad and
  funny").

**Amazon.**
- *Semantic Product Search* trains the matching model on **what customers
  searched and then bought**, so "something warm for a winter run" learns to
  find thermal leggings from real outcomes.
- It runs **alongside lexical matching**, then a separate ranking stage.
- Every search keeps teaching the system, through clicks and purchases.

**The pattern.** *Understand the prompt → retrieve by meaning **and** by keyword
→ rank by **the person's own taste** and by outcomes → let them refine → keep
learning.*

## 3. How ours works today

1. **The LLM reads the prompt** (qwen2.5, local). A normaliser translates it to
   English and classifies it, then two extractors produce `SearchCriteria`:
   interests, interest groups, skills, a named entity, location, gender and age.
2. **Two query vectors.** An entity vector (resolved through the
   `interest_entities` alias table, which learns new aliases) and a general vector
   (interests + skills). With neither, the whole intent is embedded.
3. **pgvector over `user_embedding_chunks`.** Take the 200 nearest chunks
   (profiles and public posts), keep those with similarity ≥ 0.6, and credit
   people who reacted to matching posts as well. Each user scores
   0.7 × best chunk + 0.3 × average of their top 3.
4. **Personalisation.** 0.85 × that score + **0.15 × (your profile text ↔ their
   profile text)**. Nothing else about you is used.
5. **Hard filters.** Mode, location or radius, gender, age, blocks, existing
   connections, and **every interest group must match** (substring on declared
   interests or matching posts).
6. **Merge.** 0.7 × entity result + 0.3 × general result, plus match evidence
   ("posted about X", "commented on Y", "member of Z").

**Already ahead of a plain vector search.** Structured prompt understanding
(gender, age, place, entity), entity aliases that learn ("KNY" → *Demon Slayer*),
English normalisation on both sides (it lifted Vietnamese matches from 0.39 to
0.78), evidence on every result, and privacy and block rules built into the query.

## 4. Side by side

| | Spotify | Netflix | Amazon | **ConnectSphere** |
|---|---|---|---|---|
| Understands a vague prompt | LLM | LLM (testing) | trained model | **LLM ✓** |
| Meaning-based retrieval | dense retrieval | ✓ | trained on behaviour | **pgvector ✓** |
| Keyword leg alongside it | ✓ | ✓ | ✓ lexical | **✗** |
| Ranks by the searcher's taste | listening history | viewing history | purchase history | **15 %, profile text only** |
| "Like me" / "same as me" | implicit | implicit | implicit | **✗. Becomes "query unclear"** |
| Learns from what happens next | ✓ | ✓ | ✓ the core of it | **✗. Logs query + mode only** |
| Refine without retyping | ✓ "less upbeat" | - | filters | **✗** |
| Explains the result | - | rows ("because you watched") | - | **evidence chips, no sentence** |
| Never a dead end | - | alternatives | ✓ | **✗. Often 0 results** |
| Diversity | ✓ | ✓ | ✓ | **✗** |

## 5. Measured on our data

Run against the local backend as the test account `coldstart_test1`
(interests: Hiking, Photography, Anime; Hobby mode; 256 users, 352 chunks).

| Prompt | Results | What exists in the database |
|---|---|---|
| "someone chill to do film-photography walks around Saigon on weekends" | **0** | 3 photographers in HCMC. The LLM invented a second group, *walking/walks*, and **nobody** has that interest, so the AND filter removed everyone |
| "a study buddy into the same stuff as me for the iOS exam" | **0** (`query_unclear`) | 28 people list iOS or Swift. "iOS" stayed only in the intent sentence; "same stuff as me" can't be embedded |
| "tìm người thích du lịch khám phá" (travel and exploring) | 2 | 8 people list travel |
| "tìm bạn chơi game online cùng" (online gaming) | 3. The top one doesn't list gaming | 5 people list gaming |
| "Lý Thảo" (a display name) | 3 unrelated people; **@lythao not found** | @lythao exists, display name *Lý Thảo* |

**Retrieval quality without the filters**. Share of the top 10 users (by best
chunk) who actually list the interest:

| Query | Plain query | With mxbai's query instruction |
|---|---|---|
| anime | 10 / 10 | 10 / 10 |
| photography walks | 7 / 10 | 7 / 10 |
| online gaming | 4 / 10 | 4 / 10 |
| iOS with Swift | 3 / 10 (28 exist) | 3 / 10 |
| travel and exploring | 0 / 10 * | 0 / 10 * |

\* The top 10 for travel is filled by ~60 seeded test accounts (`p1_…`, `p2_…`,
`pu_…`) that share a few identical template profiles. That is test data, not
the algorithm, but it shows that near-duplicate profiles crowd results when
nothing diversifies them.

**Two things this measured that the plan assumed:**

- **Query instructions don't help us.** mxbai-embed-large's recommended
  query prefix ("Represent this sentence for searching relevant passages: ")
  changed no ranking and lowered every similarity by about 0.02. Google's 30–40 %
  is for its own task-type model. Not worth doing here.
- **One prolific poster filling the 200-chunk pool doesn't happen yet.** The
  most any user held of the pool was 5 chunks. It is a future risk, not today's
  problem.

## 6. Where ours is weak

| # | Weakness | Severity | Shown by |
|---|---|---|---|
| 1 | **Hard filters throw away real matches.** Every LLM-made interest group must match, so one invented group ("walks") empties the result. 0.6 is a hard cut, and there is no "closest matches" fallback | **Critical** | Photography prompt: 0 of 3 |
| 2 | **Your taste barely counts.** 15 %, from profile text only. The behaviour taste the feed now builds (likes, long reads, saves, shares, interest clusters, people like you) isn't used | **Critical** | Same prompt → same list for everyone |
| 3 | **"Like me" is lost.** "Same stuff as me" or "someone like me" has nothing to embed, because the searcher never enters the query | **High** | iOS study-buddy prompt: 0 of 28 |
| 4 | **No keyword leg.** Names, nicknames, and literal terms like "iOS", "Swift" or "Roblox" depend on the embedding alone | **High** | "Lý Thảo" didn't find @lythao; iOS 3 of 10 |
| 5 | **Search never learns.** `search_logs` keeps the query and mode. No searcher, no results, no taps, no connects. Weights and thresholds are hand-set forever | **High** | - |
| 6 | **The other person's side is ignored.** Active vs dormant, mutual friends (computed, then unused), shared communities, and whether they're likely to answer | **Medium** | `mutual_count` never enters the score |
| 7 | **One shot, no "why".** No "less work-related", "closer to me" or "not this kind of person"; no sentence saying why this person fits *you* | **Medium** | - |
| 8 | **No diversity.** Near-identical profiles or one topic can fill the list | **Medium** | Travel: template accounts fill the top 10 |
| 9 | **AI post search isn't personal.** Similarity plus a ±0.03 engagement nudge; ignores your taste, what you've seen, and your "Not interested" | **Medium** | `PostRanking.rankScore` |
| 10 | Pool hogging (one user's many chunks) | Low | Not observed at this scale |

## 7. Two worked examples

### "Someone chill to do film-photography walks around Saigon on weekends", the Spotify "vibe" case

- **Spotify's way.** The prompt sets the mood; *your* history decides which of
  the many matching tracks come first.
- **Ours today.** The LLM gets it right, photography, walking, HCMC, and then
  the walking group, which no one declares, removes all three photographers.
  Even without that, the 3 would be ordered by text match only.
- **After the upgrade.** Interest groups boost instead of filter, so the three
  photographers appear. They are then ordered by how close their posts are to
  **your** taste clusters (this account: photography, hiking, anime, so a
  photographer who also posts hikes ranks first), by whether you share
  communities or friends, and by whether they're active. Each gets one line:
  *"Posts street photos around District 1 most weekends. Like your photography
  picks."* A chip "Closer to me" or "Less work-related" re-ranks without retyping.

### "A study buddy into the same stuff as me for the iOS exam", the Amazon "implicit need" case

- **Amazon's way.** "Something warm for a winter run" never says "thermal
  leggings"; behaviour data fills the gap.
- **Ours today.** "Same stuff as me" can't be embedded, iOS sits only in the
  intent sentence, the query is marked unclear, and nobody comes back. Out of 28
  people who list iOS or Swift.
- **After the upgrade.** The LLM marks the prompt `like_me`, so **your** taste
  clusters join the query as extra vectors. The keyword leg catches "iOS"
  literally. People from your communities and those you share friends with rise.
  Anyone you've already dismissed in an earlier search stays down.

## 8. Upgrade plan

Ordered by the measured damage above. Each phase ships and is tested on its own;
the five prompts in §5 are re-run after each one.

**Phase S1, Never miss people who exist**
- **Keyword leg + RRF.** Postgres full-text search over chunk text (a generated
  `tsvector` with a GIN index, migration `078_search_text.sql`) and trigram
  matching on username and display names (`pg_trgm`, part of Postgres). It runs
  next to the vector search; the two per-user rankings merge with RRF (k = 60).
- **Interest groups become a boost, not a filter.** Explicit constraints the user
  stated (gender, age, place, radius) stay hard filters.
- **Never a dead end.** With nothing at 0.6, relax once (0.5, soft filters off)
  and label the list "Closest matches". *Removed in S6:* it filled empty
  searches with people who didn't match.
- *Dropped after measuring:* the mxbai query instruction (§5).

*Done (October 2026).* Same five prompts, same account, after S1:

| Prompt | Before | After S1 |
|---|---|---|
| film-photography walks around Saigon | 0 | **3**, @buinam and @kujira1307 (the HCMC photographers) and @ngomai, who posts photography |
| study buddy, "same stuff as me", iOS | 0 | **20, labelled "Closest matches"**, @kujira1307 (iOS developer) 2nd; still no real "like me" (S2) |
| travel and exploring | 2 | **8**. The people who list travel now appear |
| online gaming | 3 | 3–6. Varies with what the LLM pulls out of the prompt; when it names gaming, all who list gaming appear |
| "Lý Thảo" | @lythao missing | **@lythao first** |

Keyword-only matches carry no similarity, so their cards show no match % rather
than a made-up one.

**Phase S2, Rank by your taste**
- Reuse `FeedStore.buildTasteVectors` (behaviour clusters, cold-start picks,
  negatives pulled away).
- Score = **0.65 retrieval + 0.20 taste + 0.10 social + 0.05 activity**:
  taste = best match between your clusters and their profile or posts; social =
  mutual friends and shared communities (`FeedStore.closeness`); activity =
  decay on their last post or comment.
- **`like_me`.** The normaliser flags "like me / same as me / similar to me"; your
  taste clusters are then added as query vectors.

*Done (October 2026).*
- **Where it lives.** A last stage, `SearchRanking.rerank`, runs after fusion.
  Taste comes from `FeedStore.buildTasteVectors` plus the profiles of people you
  connected with from a search. Social is mutual connections (0.6) and shared
  communities (0.4); `closeness` itself doesn't fit here, since existing
  connections are never shown. Activity is the last post, comment or read, and
  halves every two weeks.
- **Name matches stay on top** whatever the mix says.
- **The old 15 % profile-only term is gone:** your profile is the first taste
  vector now.
- **"Like me"** is set by the analyzer or by a fixed phrase list ("same stuff as
  me", "giống mình", "hợp gu với tôi"). Up to three taste vectors then run as a
  fourth RRF list, with a 0.7 bar, because profiles all read alike at 0.6.
- **Result:** "a study buddy into the same stuff as me" now returns 20 people
  without the "closest matches" fallback. They're ranked by your taste, so the
  anime fans this account follows come first.

**Phase S3, Learn from what happens next**
- `search_sessions` and `search_results` (migration `079_search_events.sql`):
  who searched, what was shown at which rank, and what followed. Tap, connect,
  message, dismiss. Kept 90 days.
- People you connect with from a search feed your taste; people you dismiss
  sink for 30 days.
- Per search, log tap rate in the top 5, connect rate and zero-result rate. The
  numbers that show whether each phase helped.

*Done (October 2026).*
- **Sessions.** Every AI people search records a session with the people shown,
  and returns its id.
- **Taps and "Not a fit".** The app reports both to
  `POST /api/search/sessions/:id/events`.
- **Connects and messages need no app change.** A connection request or a direct
  message to someone a search showed you in the last week is credited to that
  search on the server.
- **Dismissals.** "Not a fit" sinks that person (−0.5) for 30 days, and anyone
  whose profile is ≥ 0.85 like theirs (−0.2). Tested: a dismissed first result
  dropped to 6th.
- **Health log.** The daily clean-up job logs last week's searches, zero-result
  count, top-5 tap rate and connect rate.

**Phase S4, Refine and explain**
- Chips under the results: "More like @x", "Less work-related", "Closer to me",
  "Not a fit". The LLM edits the previous criteria instead of starting over.
- One sentence per top-5 result on why they fit *you*: one batched qwen call
  grounded in their evidence and your taste, after the list is shown. The evidence
  chips stay if it fails.

*Done (October 2026).*
- **Chips.** Under AI people results: "More like @top", "Closer to me" and
  "Refine…" (free text). Each result's long-press menu has "More like @x" and
  "Not a fit".
- **Refining edits the search.** It sends the session id: the analyzer reads the
  earlier prompt with your change appended, and "Closer to me" fills in your
  city. Tested: "chỉ ở Hà Nội" kept only Hanoi people.
- **"Less work-related" was dropped.** Hobby and Work are already separate
  searches, so free text covers what's left.
- **"Why they fit you."** These come from `POST /api/search/sessions/:id/explain`,
  in the app's language, and are cached per session and language. One qwen call
  is grounded in each person's profile and latest public posts and in your
  interests. Anyone the model skips is asked for once more. Example: "Hai bạn đều
  thích du lịch và chụp ảnh."

**Phase S5, Diversity and personal post search**
- Reuse `FeedStore.spread` so one topic or near-identical profiles can't fill the list.
- AI post search adds your taste, the seen penalty and your feedback from the feed.

*Done (October 2026).*
- **Diversity.** People results are spread by city (≤ 3 of one city per 10,
  `FeedStore.spread`), but only when the prompt named no place.
- **Topics aren't spread.** A prompt about one thing should return people about
  that thing, and spreading by topic pulled weaker matches up.
- **Post search.** It adds your taste (up to +0.05), what you've already seen
  (−0.05 if seen in the last 3 days, −0.02 if earlier) and your feed feedback,
  at a tenth of its strength.
- **The match % is unchanged:** it's still the pure similarity, and a clearly
  better match still wins.
- The "never a dead end" part moved into S1.

**Tests.** 117 server tests pass, 12 of them new (`SearchScoringTests`). The iOS
app builds. Nothing has been checked by eye in the simulator yet.

## 9. Phase S6, the prompt is the gate (November 2026)

**What testers found.** Five real testers searched in Vietnamese from one test
account (age 10, interests Anime, Books, Reading, Travel). These prompts
returned people who don't match:
- "hút thuốc" (smoking) and "chém gió" (banter);
- "thích 8 / 67 / 89";
- "người iu nam 1m8".

Several screens showed "Couldn't pick out anything specific" *and* a list.

**Why.**
1. qwen returned no interest for smoking, chatting or the numbers.
2. The server then embedded the whole sentence ("find male friend who likes
   67"), which sits at cosine ~0.55 from every profile.
3. The "closest matches" retry at 0.5 let those generic profiles through.
4. Taste (20 %) ordered them, so the account's anime taste put anime fans first.
5. "thích 8" was read as "aged 16 or under".

**The rule now.**
- The prompt decides **who qualifies**: every topic it names must be matched.
  Taste, social ties and activity only order the people who qualify.
- **A topic is matched** when the person picked it or something under it
  (Sports includes Football, never the reverse), wrote its exact words in
  their profile or a public post, or has a post within 0.64 of the topic
  embedded on its own.
- **0.64** sits between the closest unrelated post found (0.62) and the
  weakest real one (0.65).
- **Exact words, not stems**, because stemmed "chatting" is "chat", and any
  "let's chat about it" post would count.

**Topics** come from the new **interest catalogue** first (migration
`080_interest_catalog.sql`: 136 entries, 13 categories, Vietnamese and English
aliases), so slang the LLM drops still counts. "chém gió" is Chatting / Banter.
qwen's own interests, entity, skills and roles are added after that.

**Answers instead of guesses.** Each of these returns no one, with a message:

| Prompt | Warning |
|---|---|
| A topic no one has ("hút thuốc") | `no_match` |
| Topics no one has together | `no_match_together` |
| Nothing to search for ("thích số 67") | `query_unclear` |
| Height, weight or looks ("1m8", "50kg", "đẹp trai") | `unsupported_trait` |
| Partner wording ("to date", "người iu", "tìm ny") | not refused: the wording is dropped and the rest (gender, place, interests) is searched; nothing left → `query_unclear` |

A bare number is never an age unless "tuổi" or "years old" follows it.

**Other behaviour.**
- A prompt with only filters ("bạn nữ ở Hà Nội") lists everyone who passes
  them, nearest your taste first.
- A typed name ("Lý Thảo") is still found whatever else the prompt says.
- **Removed:** the whole-sentence vector, the 0.5 retry and the
  `closest_matches` warning.
- **Post search** follows the same rule.

**Interest picker.** Like Bumble's badges, Tinder's passions and Meetup's
topics:
- Interests come only from the catalogue, at most 10, most-picked first, with
  the Lifestyle section (smoking, drinking, chém gió…) last.
- A "Category · specific" item (Gaming · Roblox) must name something real (a
  known entity, or one found on Wikipedia).
- Anything missing can be suggested for review (`interest_suggestions`).
- The same check runs on every save: sign-up, persona setup and edit profile.
  Picks made before the catalogue stay valid.

**Partners.** Search is for friends and colleagues, so normal search no longer
pairs "dating intent" with the opposite gender. A Dating space was built and
archived (`legacy/dating/`); partner wording in a prompt is simply ignored.

**Tests.** 19 new server tests: `SearchConceptTests` and `InterestRulesTests`.

