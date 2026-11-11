# ConnectSphere, design decisions

Looks the user has signed off on. Keep them when changing the screens they
cover; change one only when asked, and update the entry here.

## Profile cover photo

`Core/Components/CoverHeader.swift`, the `cover` mask. Used on profiles,
community member profiles and Marketplace seller pages.

- The photo stays fully solid down to **75%** of its height.
- Below that it fades into the blurred copy of itself behind the card:
  80% opacity at 86%, 40% at 95%, clear at 100%.
- So the fade covers about the bottom quarter. A third (solid only to 62%)
  hid too much of the photo; a shorter fade shows the photo's edge as a line.
- The top fade under the clock and buttons is separate and unchanged.

Approved 2026-11-10.
