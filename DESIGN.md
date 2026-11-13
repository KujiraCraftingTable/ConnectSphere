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

## App icon

`ConnectSphere/Assets.xcassets/AppIcon.appiconset`, built by `scripts/app-icon/make.py`.

- The default icon is the **blue** whale, matching the default theme colour.
- Every other theme colour (amber included) is an alternate icon in
  Settings › App icon, named `AppIcon-<id>`.
- The picker shows whatever iOS has on the home screen, not a saved choice.

Approved 2026-11-12.
