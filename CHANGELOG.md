# Changelog

All notable changes to ClipDiary are documented here, written for a human
reading what's new — not a raw commit log.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/)
(`MAJOR.MINOR.PATCH`).

## [1.6.0] - 2026-06-18

- New **Import ▸ Import 1SE Data Export…**. If you request your data from the
  1 Second Everyday website ("Download Your Data") and unzip it, ClipDiary can
  now read that folder directly: it picks up every snippet's real date from the
  export, so there's no scanning, OCR, or date-guessing like there is when
  importing a mashed-together 1SE video. Choose the unzipped folder, pick which
  of your 1SE projects to bring in, and each clip is copied in on its own day,
  at its full length, with the date stamp on and its **1SE caption** carried
  over — matching how it looked in 1SE. Tip: import each 1SE project into its
  own ClipDiary project (create or open the destination first).

## [1.5.0] - 2026-06-18

- The calendar's month title is now clickable: it opens a small popover with
  a year stepper and a grid of all twelve months, so you can jump straight to
  any month or year (or back to "this month") in one or two clicks instead of
  stepping through with the arrows. The familiar prev/next-month chevrons are
  still there for one-step navigation.

## [1.4.0] - 2026-06-17

- Importing a 1SE video now fixes misread dates automatically. A 1SE export
  always plays its days in order, so any date the scan reads "out of order"
  (jumping back in time, or into the future) is a misread — usually a busy
  background making the burned-in date stamp briefly unreadable. ClipDiary now
  snaps each misread back onto the day it actually belongs to and re-joins the
  pieces of a day that a misread had split apart. Previously a single day could
  turn into stray clips on the wrong dates (e.g. parts landing on "Feb 03 2025"
  and "Feb 08 2026" instead of all on "Feb 08 2025"); now it stays one clip.
- The import review screen now shows a frame from each day, highlights the
  auto-corrected days (including what their stamp was misread as) so you can
  verify them at a glance, and lets you adjust any date inline before importing.

## [1.3.0] - 2026-06-16

- Polished the card editor: the card now sits at the top of the canvas (with
  any extra height left empty below) so it lines up with the inspector, instead
  of drifting toward the bottom of a tall window.
- Added a hairline frame around the card on the canvas, so a card whose
  background matches the window (e.g. white) still shows its exact extent.
- Added a "Grid" toggle to the card editor toolbar that overlays an evenly
  spaced dotted grid (10 columns × 6 rows) to help line elements up and judge
  spacing to the edges. It's a view aid only and isn't saved with the card.
- Replaced the text-size slider in the card editor with a number field (shown
  as a percent of the card height) plus up/down arrows, so a size can be typed
  or nudged precisely.

## [1.2.0] - 2026-06-16

- Reworked the review window into two columns: the photo or video (with its
  trim/crop controls) now fills the whole left side and is much larger, while
  tags, caption, transition, the day picker, the date-stamp toggle and the
  item's day/file context moved to a pane on the right. The context now reads
  as a single line (e.g. "Thu, May 28, 2026 5:30 PM") above the position and
  file name. Revert and Add to Clips sit at the bottom of that pane. Drag the
  divider to resize the pane (the width is remembered). The per-day clip editor
  keeps its single-column layout.
- Moved the "undated" jump button out of the review window and onto the
  calendar toolbar, where it opens the review window straight on the undated
  photos and videos.
- For Live Photos in review, the "Live Photo" label and the Photo/Video switch
  now sit in the media column instead of a top bar, so the right pane lines up
  with the top of the photo.
- Added a "Preview Day" button to the review window's picked-clips strip (shown
  when the day has clips) so you can play back the day without leaving review.
- Each project now remembers the calendar month you were last viewing and
  returns to it when reopened, instead of always jumping to the current month.
- Made the clip caption in rendered videos a bit smaller (about 22% smaller
  than the date stamp) so it sits less heavily over the footage.

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
- Preview window: dropped the orientation label in the top-right corner, and
  **Esc** now closes the window like the app's other windows.

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
