# Changelog

All notable changes to ClipDiary are documented here, written for a human
reading what's new — not a raw commit log.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/),
and versions follow [Semantic Versioning](https://semver.org/)
(`MAJOR.MINOR.PATCH`).

## [1.23.1] - 2026-07-02

Robustness and speed fixes from the soundtrack feature's code review:

- **A song whose file goes missing or can't be read no longer vanishes from
  the Soundtrack window.** It stays visible in the lane and the track list, so
  it can still be selected and removed — before, such a track was stuck in the
  project with no way to reach it.
- **The day editor's music bar no longer claims a song is playing where it has
  actually run out.** A short song placed open-ended used to show as "playing"
  over every later clip forever — hiding their "＋ Add music" bar. Each track
  now records its file's length when added, and the bar respects it.
- **A safety net against overlapping songs.** Degenerate data left by later
  clip edits (e.g. re-trimming a clip two songs met on) could make two songs
  play at once; spans are now clamped at render so what plays always matches
  what the lane shows.
- **Errors now appear over the Soundtrack window itself.** "A song already
  starts on that clip" (and file-copy failures) used to alert on the main
  calendar window, which could be behind or on another screen.
- The **Listen** playhead keeps moving (and the preview still stops at the
  trim window's end) while a menu is open or the window is being resized.
- **Faster on big projects:** song waveforms are decoded once and cached
  (reopening the Soundtrack window is instant), several songs load in
  parallel instead of one after another, dragging a block no longer rescans
  every clip on each mouse move, and browsing the main timeline does less
  per-frame bookkeeping.

## [1.23.0] - 2026-07-02

Soundtrack window polish:

- **Clicking a clip's thumbnail opens the day editor** on that clip — the same
  shortcut the main window's timeline view has.
- **A new song now fits the clip you click**: it starts at the clip's start
  (not at the exact spot you clicked, which used to leave a sliver of silence)
  and ends with the clip. If an earlier song spills into that clip, the new
  one starts right where it ends instead.
- **Long clips draw as a filmstrip**: the thumbnail repeats to fill the clip's
  width, instead of one left-aligned frame followed by an empty gap.
- The timeline now keeps a small margin on **both** sides of the window — the
  right edge used to sit flush.
- **Esc closes the Soundtrack window.**

## [1.22.0] - 2026-07-02

- **Songs can now be trimmed in the Soundtrack window.** Selecting a track
  shows the whole song's waveform under the volume slider, with a yellow
  window over the part that plays — the same idiom as trimming a video. Drag
  the left edge to cut into the song (skip a long intro: the block on the
  timeline starts later, and everything you keep stays in sync with the
  picture), drag the right edge to set where it stops, or drag the window
  itself to slide *which part* of the song plays without moving the block on
  the timeline at all. Edge drags respect neighbouring tracks, just like
  dragging blocks in the lane.
- A **Listen** button next to the trim bar plays exactly the selected part of
  the song (with a moving playhead), so you can check a cut by ear before
  previewing the whole video.
- The trim bar **zooms** (−/+ buttons, up to 64×), keeping the selection
  centered as you zoom — so a few-seconds window on a four-minute song is
  comfortable to grab and adjust instead of a few pixels wide. When zoomed,
  drag the waveform outside the selection (or scroll sideways) to pan along
  the song.
- **Restore Full Length** now also clears the trim, going back to the whole
  song from its top.

## [1.21.0] - 2026-07-02

- **The Soundtrack window's Preview button now plays what's on screen.** It
  used to preview the month the window was opened from, which went stale the
  moment you scrolled somewhere else. Now it previews exactly the days scrolled
  into view (edge days that are partly visible count in full), and its label
  names them — "Preview Jun 12 – 28" — updating live as you scroll. So you
  scroll to choose *where* and zoom to choose *how much*: zoom in to audition
  one transition, zoom out to run several months.
- Removed the "Drag a song to move it…" hint caption from the Soundtrack
  window's header — the controls explain themselves by now, and the header
  reads cleaner with just the Preview and zoom buttons.

## [1.20.0] - 2026-07-01

- **The Soundtrack window now has a track list.** Below the timeline, a table
  lists every track in the order it plays, showing which day it starts on, how
  much of it is **Used** (how long it plays here) and its **Total** length (the
  full audio file). Click a row to select that track — it highlights in the
  timeline above and scrolls into view if it's off-screen — so you can jump
  between tracks without hunting along the timeline.
- **Rename a track.** The selected-track panel (to the right of the list) now
  lets you give a track a friendlier name instead of the imported file name; it
  also shows how much of the track plays vs. its full length, and holds the
  volume slider, a Remove button, and…
- **Restore Full Length.** One click extends a track back to playing its whole
  audio file. If another track is in the way it's extended only as far as it
  fits, with a warning explaining why.
- Removed the track's numeric "starts at … seconds" field from the editor — it
  wasn't useful; the timeline and the list's day/length columns already show
  where a track sits.
- **You can now drag a track past another to reorder it.** Previously a track
  stopped when it bumped into its neighbour; now dragging its body far enough
  leaps it over the other track into the free space on the far side (as long as
  there's room), so moving an early track to play after a later one just works.
- A new track's name now defaults to the file name **without its extension**
  (e.g. "Summer Song" rather than "Summer Song.mp3").
- Removing a track now selects the next one (or the previous one if it was the
  last), so you can delete several in a row without re-selecting each time.
- **The video's edge fades now take the music with them.** When Create Video's
  Cover/Ending is None and a fade-in/fade-out is set, the background music
  ramps in and out together with the picture instead of playing at full volume
  through the fade and cutting off. A clip fading mid-video still leaves the
  music untouched — only the video's own edges duck it.
- **Fixed: music placement in tag-filtered videos.** Rendering with a tag
  filter used to lay songs at the wrong times once the filter skipped clips;
  the music now stays aligned with the clips it was placed over and skips
  across the filtered-out stretches (resuming mid-song), the same way the
  picture skips those days.
- **Soundtrack robustness.** Deleting or re-dating clips no longer breaks the
  songs placed around them: a song whose end clip goes away now ends on the
  clip before it (instead of silently stretching to the end of the project),
  a song whose span collapses stays visible and editable over its start clip
  (instead of vanishing from the timeline while still being in the project),
  and dragging one song onto a clip that already starts another snaps back
  (instead of silently destroying it). Adding a song over such a clip now
  explains why it can't, instead of doing nothing.

## [1.19.0] - 2026-06-30

- **Add music right in the day editor, as a bar under the clip.** The side-pane
  "Soundtrack" status is gone; in its place a music bar sits directly beneath the
  clip's own audio waveform (and under the photo for photo clips). When nothing
  is playing over the clip it reads "＋ Add music" — click it, pick a song, and
  it's laid over the clip (starting when the clip starts, ending when it ends)
  with its waveform shown right there. Once music is on a picked clip the bar is
  read-only and clicking it opens the Soundtrack window to fine-tune the timing,
  span, or volume.
- **You can now add music while reviewing an "available" clip**, before adding it
  to the day — just like trimming or cropping. Preview Trim and Play both play
  the video with the song mixed on top, so you can hear the combination first;
  when you add the clip, the music comes with it. (A song added to a clip you
  then skip without adding is cleaned up automatically.)

## [1.18.1] - 2026-06-30

- **Fixed: black video when previewing/exporting a range that a song spills out
  of.** If a soundtrack song started inside the chosen range but was set to stop
  on a clip *outside* it (e.g. a May song that ends on a June clip), previewing
  just May played the audio over a black picture, while previewing everything
  looked fine. The song was being laid down a few milliseconds past the end of
  the last video, which left the rendered video "uncovered" at the very end and
  turned the whole picture black. Songs are now trimmed exactly to the end of
  the video, so the range previews and exports correctly.

## [1.18.0] - 2026-06-30

- **Day window: music moves to the Soundtrack timeline.** The clip editor no
  longer has inline audio controls. Instead it shows a read-only **Soundtrack**
  status — which song plays over the current clip, and whether it starts here or
  carries in from an earlier day — and a button to jump to the Soundtrack window
  to make changes. When a clip has no music, **Add Music…** lets you pick a file:
  it's placed starting on that clip and the Soundtrack timeline opens on that day
  with the new song selected, ready to position. All timing, volume, and
  start/stop editing now lives in one place — the Soundtrack window.

## [1.17.4] - 2026-06-30

- **Soundtrack timeline: bigger clip thumbnails.** The clip strip is 50%
  taller so thumbnails are easier to make out, each clip now has rounded
  corners, and the "Clips"/"Audio" row captions (redundant once you've used it
  once) are gone.

## [1.17.3] - 2026-06-30

- **Soundtrack opens where you're already looking.** The Soundtrack window now
  lands on the same stretch of time the main window is showing: open it from the
  calendar on May 2026 and it scrolls to May 2026; open it from the timeline
  scrolled to a particular day and it scrolls to around that day, instead of
  always jumping to the last-viewed calendar month.

## [1.17.2] - 2026-06-30

- **Soundtrack timeline: much faster on big projects.** Opening the Soundtrack
  on a project with thousands of clips no longer hangs on a spinner, and
  scrolling/zooming is smooth again. The timeline now only builds (and decodes
  thumbnails for) the clips actually scrolled into view instead of the whole
  project at once, skips thumbnails for slivers too thin to show one, and
  caches the timeline layout and day/month grid so they aren't recomputed on
  every scroll frame.

## [1.17.1] - 2026-06-30

- **Soundtrack timeline: clearer month boundaries.** Added a month-name row
  above the day numbers (the day row now just shows the day number). The month
  name stays in view as you scroll — as long as any of a month's days are on
  screen, its name is too. A full-height line divides one month from the next,
  while the lighter day separators stop just below the month name, and thin
  rules underline both header rows.

## [1.17.0] - 2026-06-29

- **New: lay audio tracks over your clips.** In the clip editor (video or
  photo) you can now **Add Audio…** — pick an mp3, wav, m4a, etc. — to play a
  song or sound over a clip in the rendered video. The audio **mixes** with the
  clip's own sound and **plays on its own over photos** (which are silent).
  - **Start offset:** choose when the audio begins relative to the clip — `0`
    plays them together, a **positive** value starts it later (silence first),
    a **negative** value means the song is already partway in when the clip
    begins.
  - **Spanning multiple clips:** set a track to play for *Multiple clips* and it
    keeps going across the following clips. To stop it, open a later clip and
    click **"End audio here."** If the file is shorter than the span, it plays
    once and then goes silent (no looping).
  - **Volume:** each audio track has its own 0–400% level (boosts above 100% are
    only audible in the saved file, like clip volume).
  - Audio files are copied into a new **`Audio/`** folder in the project, and
    are cleaned up when the clip using them is deleted. Back up `Audio/`
    alongside `Clips/`.
- **New: a Soundtrack timeline.** A new **Soundtrack** toolbar button opens a
  timeline of your clips laid end-to-end, with an audio lane beneath. Click an
  empty part of the lane to add a song; drag a song to reposition it, drag its
  right edge to set where it stops and its left edge where it starts. Songs
  never overlap, and what you see is exactly what renders. Zoom in/out and
  preview the month from the same window.

## [1.16.1] - 2026-06-29

- **Fixed: cropping a Live Photo's still could save it as an unplayable
  video.** When adding a Live Photo, switching between its **Photo** and
  **Video** options could leave the still image saved as a video clip — it
  showed a blank thumbnail, wouldn't play in the editor, and broke that whole
  month's preview/export with a "Cannot Open" error. The copied file now always
  matches what the clip actually is. (An existing bad clip can be fixed by
  removing and re-adding the photo.)

## [1.16.0] - 2026-06-24

- **Crop videos.** The trim editor now shows a yellow crop box right on the
  video, just like the photo editor — drag the corners to zoom in and drag inside
  to reposition. The crop keeps the video's shape (it zooms and pans, never
  stretches) and the same crop applies to the whole clip, showing up in the day
  window, the preview, and the exported video. Use **Reset Crop** to go back to
  the whole frame.
- **Player controls moved off the video.** Because the crop box sits on top of
  the video, the floating controls that used to overlay the picture are gone.
  Instead there's a play/pause button next to Preview Trim, and **Space** toggles
  play/pause (as the old controls did). The filmstrip still shows the playhead.

## [1.15.0] - 2026-06-22

- **Keyboard shortcuts cheat sheet.** ClipDiary works best with the keyboard, so
  there's now a window listing every shortcut, grouped by where it's used —
  projects, the calendar, the day window, and the trim and photo editors. Open it
  from **Help ▸ ClipDiary Keyboard Shortcuts** or just press **⌘/** anytime.
- **Shortcut hints in tooltips.** Hovering a control that has a keyboard shortcut
  now shows the key in its tooltip, including the Project Settings button (⌘,) and
  the trim editor's ← / → skip.

## [1.14.0] - 2026-06-22

- **Audio waveform under the trim filmstrip.** The video trim editor now shows
  a waveform of the clip's audio in a slim lane beneath the thumbnail strip,
  aligned to the same timeline. You can see at a glance where someone starts and
  stops speaking, making it easy to set the in/out points right at those moments.
  The waveform dims along with the filmstrip outside the selected range, and
  clips with no audio simply show the filmstrip as before.

## [1.13.0] - 2026-06-21

- **New Timeline view.** A toolbar switch (top-left) now flips the main window
  between the month **Calendar** and a new **Timeline**: one continuous scroll
  across your whole project, with every day that has clips shown as a row of its
  clip thumbnails, grouped under sticky month headers. It opens scrolled to the
  month you were viewing, and the tag filter still scopes it. Clicking any clip
  opens that day's editor with that exact clip already selected. Your choice of
  Calendar vs. Timeline is remembered between launches.

## [1.12.0] - 2026-06-21

- **Smoother audio at every cut.** The video still cuts hard between clips (no
  dissolve), but each clip's sound now dips briefly to silence right at the
  join — fading out over its last ~0.06s and in over the next clip's first
  ~0.06s. This matches what the 1 Second Everyday app does and removes the
  abrupt jump in volume / room tone (and the occasional click) you'd hear where
  two clips with sound were spliced together. The very start and end of the
  video are unchanged — those are still governed by the per-period cover/ending
  fades. Applies to both Preview and the saved file.

## [1.11.1] - 2026-06-20

- **Fixed phantom thumbnails after switching projects.** Creating or opening a
  new project while the calendar was still drawing the old one's thumbnails
  could leave stale thumbnails stuck on some days — days that were actually
  empty in the new project (clicking them showed nothing and the clip count read
  0). The calendar now discards a thumbnail load that finishes after the project
  has already changed.

## [1.11.0] - 2026-06-20

- **Copy a clip to another project ("post to project").** When you're editing a
  picked clip in the day window, a new **Copy to Project** button copies that
  clip — its trim, crop, tags, caption, date, volume and fade — into another
  ClipDiary project. This mirrors keeping one shared timeline for all the kids
  and pulling a handful of clips into each child's own project (e.g. for a
  birthday video), where you're then free to retime or add to them
  independently. The menu lists the projects you copied to recently for
  one-click reuse, and **Choose Project…** lets you pick any project folder. A
  title card placed on a day can be copied too — its design comes along.
  Re-posting the same clip reuses the media already in the target instead of
  duplicating the file.

## [1.10.1] - 2026-06-20

- **The app now has its own icon.** A colourful filmstrip-with-play-button tile
  (sunset gradient) replaces the blank default icon, so ClipDiary is
  recognisable in the Dock, Launchpad, and the app switcher.

## [1.10.0] - 2026-06-20

- **Cards are now live everywhere they're used.** Editing a card — its text,
  colours, image, or layout — now flows through to every place it appears the
  next time you preview or save a video: its covers, its endings, and any day it
  was placed on. Previously a card was frozen into a snapshot the moment you
  used it, so later edits didn't show up. (Re-rendering an existing video will
  now reflect the card's current design.)
- Because of this, a card no longer carries its own "show for" duration. A card
  placed on a day keeps its own display duration (adjust it with the duration
  stepper in the editor, just like a photo), and the **Cover** and **Ending**
  cards get a new "show for N.Ns" duration control right in the Create Video
  window, set per time range.
- The card editor now shows a **"Where it's used"** panel — which time ranges
  use the card as a cover or ending, and which days it appears on — so before
  editing you can see what a change will affect, and Duplicate it first if you'd
  rather leave those videos as they are.
- Selecting a card in the day editor now has an **"Edit Card…"** button that
  opens that card straight in the card editor; when you close it, the day's
  preview updates to the card's new design.
- The Cards gallery now shows a **usage count** under each card ("3 uses"),
  with a tooltip breaking it down by days / covers / endings — at a glance you
  can tell which cards are in use before editing or deleting them.

## [1.9.0] - 2026-06-20

- The **Cover** and **Ending** cards (and their fades) in the Create Video
  window are now remembered **per time range**. Set a cover and ending for
  "2025", switch the range to "May 2026" and the selectors reset to None so you
  can choose that month's own bookends — switch back to "2025" and your earlier
  choices reappear. Each month, year, custom span, and "All clips" keeps its own
  cover/ending, and Preview and Save use whichever belongs to the chosen range.
- When **Cover is None**, the fade button now offers **"Fade in first clip"** —
  the video opens by fading the first clip up from black. Likewise, when
  **Ending is None**, **"Fade out last clip"** fades the last clip to black at
  the end (video, audio and date stamp together). Both are remembered per time
  range alongside the cover/ending choices. This replaces the old project-wide
  "Fade out the last clip" setting, which has been removed from Project Settings
  — the ending fade now lives in the Create Video window, per range.

## [1.8.0] - 2026-06-19

- Video clips now have a **volume control** in the clip editor. Each clip
  defaults to 100% and can be dialed anywhere from 0% (muted) to 400% (boosted —
  useful for a very quiet clip) with the slider; click the speaker icon to snap
  back to 100%. The level is applied to the exported video and rides along with
  any fade in/out. The in-app preview reflects muting/attenuation but plays
  boosts above 100% at 100% (a player limitation) — use Save… to hear a boost.
  Photos are silent, so they don't show the control.

## [1.7.0] - 2026-06-19

- The Review window and the per-day editor are now **one window**. Clicking a
  calendar day opens it on that day's already-picked clips (and its "Review
  Sources…" right-click option opens it on the day's source media). The separate
  "Edit Day" window and the per-cell **+** button are gone.
- A new **left thumbnail rail** shows the whole day at a glance: a *Picked*
  section (the clips you've added — click to edit, drag to reorder) and an
  *Available* section (every photo/video captured that day, with an "✓" badge on
  ones you've already used). Click any thumbnail to jump straight to it instead
  of only stepping through with ↑/↓.
- **Previous / Next Day** toolbar buttons (`<` / `>`) step between days that
  have media, without going back to the calendar.
- Editing a picked clip now uses the same roomy two-column layout as reviewing
  (big media on the left, all the controls in a side pane), so editing and
  reviewing look and feel the same.

## [1.6.1] - 2026-06-18

- Much faster on large libraries (thousands of clips). Moving between months in
  the calendar used to take several seconds because every day cell rescanned the
  whole library; days are now looked up by an index, so navigation is near
  instant. Switching between clips in a day's editor was also slow — it re-saved
  the entire library on every click even when nothing changed; it now only
  writes when there's an actual edit.

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
