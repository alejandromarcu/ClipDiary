# Changelog

All notable changes to ClipDiary are documented here, written for a human
reading what's new — not a raw commit log.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/)
(`MAJOR.MINOR.PATCH`).

## [1.1.1] - 2026-06-16

- The day editor now opens in its own window and remembers its position and
  size between openings, matching the review window.
- Press **Esc** to close the review window, like the app's other windows.
- Renamed the card text "Colour" label to "Color".
- Fixed "Preview Day" (and the month/year preview) not reflecting a clip's
  unsaved edits — caption, transition, trim and the like now show up in the
  preview right away.
- Video players no longer dim the picture when the playback controls appear on
  hover, so you can keep watching without moving the mouse away.
- Deleting a clip in the day editor now keeps the window open and moves to the
  previous clip (or the next one), closing only when the last clip is removed.
- Photo display duration: the value can now be typed into a box, the **−** and
  **+** keys adjust it, and a newly reviewed photo defaults to the duration you
  last used (remembered per project).
- Fixed the letterbox bars (e.g. beside a portrait photo) flashing green during
  a clip's fade in/out — they now stay black throughout the transition.

## [1.1.0] - 2026-06-16

- **Separate "review" and "edit" on each calendar day.** Hovering a day cell
  reveals a **+** button in its bottom-right corner that opens the review window
  to add that day's clips. Clicking anywhere else on the day opens the day editor
  to rearrange, retrim, or add a card to the clips you've already picked —
  which works on empty days too.

## [1.0.0] - 2026-06-16

First tracked version. ClipDiary is a native macOS app for making "1 second
a day" style monthly memory videos, with:

- A project-based library with a month calendar view.
- **Source folders + review workflow**: point at a folder of photos/videos,
  then step through each day's media to pick, trim, and crop clips.
- A trim editor for videos (drag in/out points on a filmstrip) and a crop
  editor for photos, with adjustable display duration.
- Live Photos support (choose the still or the motion clip when picking).
- Tags, captions, and per-day reordering of clips.
- A burned-in date stamp on rendered video, toggleable per clip.
- Per-clip fade transitions (picture, audio, and date stamp).
- Title cards (covers, endings, day slides), pasted in with ⌘V.
- Preview and export for a month, a year, a custom date range, or the whole
  library, with portrait/landscape orientation and an optional ending
  fade-to-black.
- Importing one-off media files and splitting a mashed 1 Second Everyday
  export into per-day clips.
