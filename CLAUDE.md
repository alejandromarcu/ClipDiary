# ClipDiary

## What this app is

A native macOS app (SwiftUI + AVFoundation) for making "1 second a day" style
monthly memory videos — inspired by the 1 Second Everyday (1SE) mobile app,
which has no desktop version. Built for personal use on a big screen.

Deliberate improvements over 1SE:
- Clips can be **any length** (1SE caps snippets at ~10 seconds).
- Trimming uses **in/out points dragged on a filmstrip** (cut the beginning
  AND the end), not "pick a start time + fixed duration".
- Simpler overall: no accounts, no cloud, everything local.

## Architecture (one file each)

- `ClipDiaryApp.swift` — app entry, injects `LibraryStore` as environment
  object. File-menu commands (replacing `.newItem`): New Project… (⌘N), Open
  Project… (⇧⌘O — plain ⌘O is the trim editor's Set Out), Open Recent ▸ submenu
  + Clear Menu. Declares the windows: the main calendar, plus value-keyed
  WindowGroups for Preview (`PreviewRequest`), the day window (`ReviewRequest`),
  and the **Soundtrack** timeline (`SoundtrackRequest`), and id-keyed Cards /
  Keyboard Shortcuts windows.
- `Models.swift` — `Clip` struct (id, fileName, date, inSeconds, outSeconds,
  durationSeconds, createdAt, tags, kind, crop, cardID, sourcePath, sourceHash,
  sourceBytes, audio) + date/time helpers. (`id` is a random `UUID`, not a content
  hash.) A clip is a video or a photo (`ClipKind`); photos store their
  display duration in durationSeconds/outSeconds and an optional `CropRect`
  (unit coords, top-left origin). A clip with `cardID` set is a **live
  reference to a designed card** (`isCard`): a `.photo` clip with no media file
  in `Clips/` — the card is rendered fresh from its current document for
  thumbnails/preview/export, so editing the card updates the placement (its
  display duration stays per-placement). Trim/crop are metadata only; media
  files are never modified (non-destructive). Tags are free-form multi-word strings,
  deduped case-insensitively. `sourcePath` records which source-folder file a
  clip was picked from: clips picked twice from one source (two segments of a
  long video) **share one copied media file**, so `delete` only removes the
  file when the last clip referencing it goes. A clip may also carry an optional
  `AudioTrack` (`audio`): a music/audio file (copied into the project's `Audio/`
  folder, keeping its original name in `displayName` for the editor) laid over
  the video — with an `offsetSeconds` (± relative to the clip
  start), a `fileStartSeconds` **trim into the file** (where in the song
  playback starts; read via `fileInPoint`, which folds in the legacy
  negative-offset skip), its own `volume`/`transition`, the file's measured
  length (`fileDurationSeconds`, recorded when the file is copied in — nil on
  older tracks), and an `endClipID`
  marking how far it
  spans in render order (`==` the start clip = this clip only; `nil` =
  open-ended; another clip id = ends after that clip — a stale reference from a
  later delete/re-date collapses the span to the start clip via
  `TimelineLayout.audibleSpan`). It mixes with the clip's
  own audio and plays alone over silent photos. `ActiveAudioRef` pairs a
  spanning track with its start clip for the editors' music bar.
  `sourceHash` (lowercase-hex
  SHA-256 of the copied media bytes) + `sourceBytes` (file size) are recorded at
  pick/import time so the project can be rebuilt by content if `Clips/` is lost
  — see "Backup / reconstruction" below. Also `ProjectSettings`
  (orientation + the remembered Create Video `renderRange` + `bookendsByPeriod`):
  a small per-project Codable blob, every
  field defaulted via `decodeIfPresent` so old projects and future options need
  no migration. `bookendsByPeriod` maps a `RenderRange.periodKey` (a canonical
  month/year/custom/all string) to a `BookendSettings` (cover + ending card ids,
  their fades, and their display durations `coverDurationSeconds`/
  `endingDurationSeconds` — cards no longer carry a duration, so the cover/ending
  one is set here per period — **plus**
  `firstClipFadeInSeconds`/`lastClipFadeOutSeconds` —
  applied when the respective card is None to fade the first clip in / last clip
  out), so the Create Video window remembers a distinct Cover/Ending per time
  range; `bookends(for:)`/`setBookends(_:for:)` read/write it (an empty value
  drops the entry). `bookendClipFades(_:)` turns those into the render-level
  fade-in/out. (There is no longer a project-wide ending fade — it moved here,
  per period.) And
  `RenderRange` (month / year / all / custom start–end): the time span a video
  covers, with `contains`/`label`/`fileNameLabel` helpers, used by both Preview
  and Export and persisted in `settings.json`.
- `LibraryStore.swift` — `@MainActor ObservableObject`. Owns the **currently
  open project**: a user-chosen directory (e.g. `~/MyClips/Amelie's life/`)
  holding `clips.json` (ISO-8601 dates) + a `Clips/` subfolder of copied media.
  Per-project `ProjectSettings` persist in `settings.json` (loaded on project
  open, defaults when absent); `updateSettings { … }` is the only mutator and
  saves immediately.
  `currentProjectURL` is nil when no project is open (→ welcome screen).
  `createProject(at:)` / `openProject(at:)` switch projects; the last-used one
  reopens on launch via a **security-scoped bookmark** in UserDefaults
  (`lastProjectBookmark`) — required because the sandbox only grants persistent
  folder access via bookmarks. A capped recents list (`recentProjectBookmarks`)
  feeds Open Recent (`recentProjects`/`openFromBookmark`). `presentNew/Open
  ProjectPanel(store:)` are the shared NSSavePanel/NSOpenPanel flows used by both
  the File menu and the welcome screen. Copies imported media into the project's
  `Clips/`, generates cached thumbnails via `AVAssetImageGenerator` (videos) or
  ImageIO (photos). A parallel `Audio/` subfolder holds copied audio-track files
  (`audioURL(for:)`); `copyAudioFile(from:)` copies a user-picked file in (the
  editor then sets the `AudioTrack` on its clip draft), `pruneUnusedAudioFile`
  deletes it when no clip references it (also from `delete`, which additionally
  re-anchors any track *ending* on the deleted clip to the clip before it),
  `setAudioTrack`/`moveAudioTrack`
  set/clear/relocate a block (the Soundtrack timeline; a move refuses to land
  on a clip that already starts another song), and `activeAudio(over:)`
  lists the tracks playing over a clip (by global render order, capped by each
  track's recorded file length so a song isn't claimed past where it runs out)
  for the editors' music bar. `timelineLayout()` (+ `orderedClips`) is the
  **shared source of truth**
  for where each clip sits on the rendered timeline (seconds), used by both the
  exporter's audio positioning and the Soundtrack view so the lane is WYSIWYG;
  its `audibleSpan(of:startingOn:)` resolves a track's placed span (offset +
  end reference, stale references repaired), and its `tracks` lists every
  placement so resolved — clamped so no span overlaps the next (the safety net
  for degenerate data left by later clip edits) — the one placement list the
  exporter, the lane, and `activeAudio` all consume. Decoded song waveforms +
  durations are memoized per file (`audioWaveform(for:buckets:)` — the files in
  `Audio/` are immutable), and `discardDraftAudio(of:)` is the one cleanup the
  editors call when a review draft that picked up music is discarded.
  `importMedia` routes by UTType. Imported clips default to the recording
  date (video creationDate / photo EXIF DateTimeOriginal, fallback file
  creation date). Also home of `loadOrientedCGImage` (EXIF orientation baked
  in — crop coords are always relative to the oriented image). Owns the
  project's **source folders** too: `sources.json` in the project root stores
  security-scoped bookmarks (`SourceFolderRecord`), resolved/accessed on
  project open and released on switch; `addSourceFolder`/`removeSourceFolder`/
  `rescanSources` maintain `sourceFolders` + the scanned `sourceItems` index
  (async `scanTask`, cancelled on changes). `pick(_:draft:from:)` copies a
  reviewed source file into `Clips/` (reusing the copy if that source was
  picked before) and registers the draft clip; `from:` chooses the still or a
  Live Photo's motion video. `availability(on:)`/`availability(inMonthOf:)`
  tally a day's/month's source videos (count + length) and photos for the
  calendar, counting Live Photos as photos.
- `SourceScanner.swift` — `SourceItem` (url, kind, optional `captureDate`)
  and the recursive directory walk: sync enumeration by UTType (image/movie),
  then an async pass loading capture times (EXIF DateTimeOriginal via the
  shared `exifCreationDate`, video creationDate). **No filesystem-date
  fallback**: files with no embedded date (chat apps strip metadata; FS dates
  would equal the album's download day) get `captureDate == nil` and sort
  into an "undated" bucket after all dated items. Skips hidden files,
  duplicates from overlapping folders, and anything inside the project
  folder itself. **Live Photos** (a still + a same-folder, same-basename
  video, e.g. `IMG_1234.JPG` + `IMG_1234.MOV/.MP4` from iPhone/Google
  exports) are paired into one photo `SourceItem` carrying the motion clip in
  `motionURL` (+ its `duration`); the motion file is not surfaced as its own
  video, so a Live Photo counts as one photo, not a phantom extra video.
- `ReviewView.swift` — `ReviewWindow`, the **day window** (one window does both
  reviewing source media *and* editing the day's picked clips). A left
  **thumbnail rail** lists the day's content in two sections: *Picked* (the
  clips already added — click to edit, drag to reorder via `reorderClips`) and
  *Available* (`store.sourceItems(on:)`, each with an "Added ✓×n" badge via
  `usageCount(of:)`). A `Selection` is `.clip(UUID)` or `.source(path)`:
  selecting a clip shows `TrimEditor`/`PhotoEditor` in library mode, a source in
  review mode on a per-item draft. ↑/↓ navigate within the active section (the
  rail auto-scrolls to keep the selection visible); the source flow runs into
  following days and finally the undated bucket. "Add to Clips" (⌘↩) calls
  `store.pick` and auto-advances. Undated items show an orange "No capture date"
  badge above the media and default their drafts to the window's day. A **Live
  Photo** shows a "Photo / Video" segmented picker (`useMotion`): Photo embeds
  `PhotoEditor` on the still, Video embeds `TrimEditor` on the motion clip; ⌘↩
  picks whichever (copying the still or the motion file). Layout splits by scope:
  the **toolbar** holds navigation (Previous/Next **Day** `<`/`>`, then item
  ↑/↓); the **rail footer** holds the day-scoped **Add Card…** and **Preview
  Day**; the editor's side pane holds the item-scoped Add/Delete/Revert. Opened
  via `ReviewRequest` (`focusSources` chooses the initial section — the + circle
  vs. a cell click; `startUndated` opens straight on the bucket; `startClipID`
  pre-selects a specific picked clip — the Timeline view clicking a clip — by
  seeding the window's `selection`, which `ensurePosition` keeps when valid).
  Also `SourceFoldersSheet` (a thin wrapper around
  the reusable `SourceFoldersSection`: add/remove/rescan source folders;
  auto-presented when a project has no clips and no sources) and
  `presentAddSourceFolderPanel`.
- `ContentView.swift` — month calendar grid (week-row `VStack`/`HStack`s, 7
  columns, respects `calendar.firstWeekday`) that fills the window height with
  hairline cell borders so cells grow when the window does. Day cells show a
  thumbnail + picked-clip badge and a source-availability footer (video count
  + length, photo count from `store.availability(on:)`); the month header
  carries the same month-wide tally. A toolbar segmented switch (`MainViewMode`,
  remembered in `@AppStorage("mainViewMode")`) flips the body between this
  calendar and **`TimelineBody`** — a continuous scroll of every day that has
  clips (`store.contentDays(taggedWith:)`), grouped under sticky month headers,
  each day a horizontal strip of `TimelineClipThumb`s; it opens scrolled to the
  calendar's current month and respects the tag filter. Clicking a timeline clip
  opens the day window with that clip pre-selected (`ReviewRequest(day:startClipID:)`).
  **Clicking a day cell opens the day window** on the day's picked clips
  (`ReviewRequest(day:)` via openWindow); the cell's **context menu** also offers
  "Review Sources…" (`ReviewRequest(focusSources: true)`, opening the same window
  on the day's source media). Toolbar: a **Project Settings** gear
  (⌘,), an Import menu (Import Media… fileImporter multi-select, Import 1SE
  Video…, Import 1SE Data Export…) and a single **Create Video…** button. Also contains
  `ProjectSettingsSheet` (orientation radio group + a `SourceFoldersSection`) and
  `RenderSheet` — the unified
  Preview/Export window: a time-range picker (`RenderMode` month/year/all/custom,
  remembered in `settings.renderRange`, defaulting to the current month), a
  **Cover/Ending** picker (per-period `BookendSettings`; with a card a "show
  for N.Ns" duration stepper appears and the fade edits the card's transition,
  with **None** the fade edits the first-clip fade-in / last-clip fade-out via
  `ClipFadeSheet`), and
  **Preview** (opens `PreviewWindow`) and **Save…** (NSSavePanel + progress bar)
  buttons, plus a video/photo count (calendar `video.fill`/`photo.fill` icons)
  and total length for the chosen range; orientation still comes from Project
  Settings (not surfaced in this window).
- `TrimView.swift` — `TrimEditor` (the video editor), plus the shared pieces:
  `LiveEditBuffer` (lets the day window flush an editor's in-flight edit before
  Preview Day, since editors only persist on disappear), `TagRow` (tag chips +
  new-tag field + reuse menu), `ClipMusicLane` (the **music bar** both editors
  draw under the clip's own waveform / the photo: empty it's a dashed "＋ Add
  music" button — pick a file and a this-clip-only track is laid over the clip,
  via the store for a picked clip or onto the draft's `audio` in review; filled
  it shows the track's waveform **read-only** — clicking opens the Soundtrack
  window, where all fine-tuning lives — and a track spanning in from an earlier
  clip (`store.activeAudio(over:)`) shows read-only too. A review draft gets a
  ✕ to drop its track instead, and its orphaned `Audio/` copy is pruned on
  revert/skip; `TrimEditor` also previews the song over Play/Preview Trim with
  a synced `AVAudioPlayer`), `DayPickerField`, `ReviewItemInfo`/
  `ReviewItemHeader`, `ResizablePaneDivider` (drag-resizes the side pane), and
  `TrimSlider` (filmstrip of 10 thumbnails with draggable yellow in/out handles,
  min gap 0.1s). Set In/Set Out buttons (⌘I/⌘O) mark trim points at the current
  playback time. "Preview Trim" plays exactly the in→out segment using a periodic
  time observer to pause at the out point. `TrimEditor` has two modes — library
  (auto-saves on disappear, can delete) and **review** (`sourceURL:` plays the
  original source file, `onAdd:` shows an "Add to Clips" ⌘↩ button handing back
  the configured draft) — both drawn in **one two-column layout**: media + trim
  controls on the left, metadata/actions in the right side pane (the action is
  Add in review, Delete in library). The day's reorder (drag clips) lives in the
  day window's rail, calling `LibraryStore.reorderClips`.
- `PhotoView.swift` — `PhotoEditor` (crop, display-duration stepper, aspect
  lock picker Free/16:9/9:16, tags, date, delete) and `PhotoCropView`
  (aspect-fit photo, draggable yellow corner handles + move-inside gesture,
  min crop 5%; an aspect lock snaps the crop and constrains corner drags).
  Same library/review modes as `TrimEditor`. For a **card clip** (`isCard`) the
  editor renders the card document instead of a file, hides the crop/date-stamp
  controls (only the display duration is editable), and offers an **"Edit Card…"**
  button that presents `CardEditorView` for the referenced card (re-rendering the
  preview on close).
- `SoundtrackView.swift` — `SoundtrackView` (+ `SoundtrackRequest`), the
  background-audio **timeline** window opened from the calendar's Soundtrack
  toolbar button. Lays the project's clips on a horizontal time axis (widths ∝
  `LibraryStore.TimelineLayout.duration`, scrolled to the anchor month, zoomable)
  with an audio lane beneath. Each `clip.audio` is a draggable block (positions
  come from `store.timelineLayout()`, identical to what the exporter renders):
  click an empty lane spot to add a file (`store.copyAudioFile` +
  `setAudioTrack`), drag the body to reposition (`moveAudioTrack` reassigns the
  start clip + offset), drag the right edge to set the stop, the
  left edge to set the start. Edge-resize drags clamp to the immediate neighbour
  (`neighborBounds`) so a track can't overlap the next, but a **body drag can leap
  over neighbours** into any free gap big enough to hold it (`freeGaps` picks the
  gap whose nearest fitting start is closest to the drag, flipping to the far
  side past the midpoint) — so dragging one track past another **reorders** it.
  Below the timeline a **track list** (`Table`, `TrackInspector`) lists every
  track in play order with its start day, **Used** length (its span here) and
  **Total** length (the audio file's full duration); selecting a row is the same
  `selected` the lane highlights (and `revealTrack` scrolls it into view if
  off-screen), so the table is a jump-between-tracks navigator. The selected
  track's side inspector renames it (a committed `displayName` draft), shows
  "Plays used of total", sets its volume, removes it, **trims it** — a
  full-file waveform with a draggable yellow window (`AudioTrimBar`, the video
  trim slider's idiom): the left edge trims where the song starts (its
  timeline start moves with it, so kept content stays put against the
  picture), the right edge where it stops, and dragging the window's body
  slides *which part* of the file plays without moving the block
  (`applyTrim`, writing `fileStartSeconds` via `moveAudioTrack`; edge drags
  clamp to the neighbour slacks). The bar **zooms** (−/+ buttons, ×2 steps to
  64×) into a horizontal scroll that re-centers on the window each step, since
  a short window on a long song is otherwise only a few pixels wide; narrow
  windows also move the yellow handles *outside* the square so its whole body
  stays a slide target. A **Listen** button plays just the windowed
  part (`AVAudioPlayer` + a stop-at-end timer, with a playhead in the bar).
  The inspector also offers **Restore Full
  Length** (`restoreFullLength`: extends the track's end back to its whole file
  *and resets the trim-in point*,
  clamped to the next track / timeline end, returning a warning when a following
  track cut it short). A Preview button renders **the days scrolled into view**
  (`visibleDayRange`: viewport metrics → grid days → a `.custom` day span, edge
  days included whole) in `PreviewWindow`, its label naming the span live — so
  scrolling picks where and zoom picks how much gets previewed.
  A track whose file is missing/unreadable still draws (uncapped) so it stays
  selectable and removable; errors from interactions here alert over this
  window, not the calendar. Waveforms come from the store's memoized
  `audioWaveform(for:buckets:)`; thumbnails reuse `store.thumbnail(for:)`.
- `MashImport.swift` — "Import 1SE Video": splits a mashed 1 Second Everyday
  export into per-day clips by OCR'ing (Vision) the date stamp burned into
  the bottom-left corner ("MAR 03 2026"). Coarse 0.3s sampling pass, then
  bisection refines each day boundary to ~1 frame; each day's range is
  re-encoded to its own MP4 (`AVAssetExportSession`, frame-accurate) and
  registered via `LibraryStore.adoptVideo(at:date:)`. Because a busy
  background can make the stamp misread (a wrong day, or even a wrong year),
  `resolveDates` then repairs the day list using the invariant that a 1SE
  mashup plays its days strictly in order: a longest **non-decreasing**
  subsequence of the dates is the trusted spine, and each out-of-order run is
  snapped onto the day it belongs to (`snapTarget`: bracketed by the same
  trusted day → that day; bracketed by different days but only the year
  misread → the neighbour sharing the month/day, e.g. a boundary "FEB 08 2045"
  sliver; at an edge → its one neighbour; otherwise left flagged), then
  same-day pieces are merged into one clip (`MashDateFlag` .ok/.corrected/
  .needsReview + `originalDates` drive the review UI). `MashImportSheet`
  drives scan → review → import phases (reached from the Import toolbar
  menu in `ContentView`); review shows a frame per day and highlights the
  auto-corrected/flagged dates for inline editing.
- `DataExportImport.swift` — "Import 1SE Data Export": the cleaner alternative
  to the mashup OCR. Reads a 1SE **"Download Your Data"** export folder (the
  GDPR zip, unzipped), whose `files/snapshots/manifest-*.json` already lists
  every project and per-snippet `date` (the timeline day) + `video_id`, with the
  actual clip at `files/snippets/<video_id>/video.mov` — so dates are read, not
  guessed. `DataExportReader.read` picks the newest non-partial manifest,
  resolves each project's snippets whose `video.mov` exists, and returns
  `DataExportProject`s biggest-first. `DataExportImportSheet` lets the user pick
  one project to import into the **current** ClipDiary project;
  `LibraryStore.importDataExportProject` copies each `video.mov` in untrimmed
  (full length, matching what 1SE plays) with the date stamp **on** (raw
  snippets aren't pre-stamped, unlike a mashup), preserving 1SE's within-day play
  order via `createdAt`. Captions are carried over too: 1SE stores them in
  `backups.json` (not the manifest) under `location_text` — a legacy field name,
  with `diary_text` an empty fallback — keyed by `video_uid`; `captionMap` builds
  that lookup (newest non-empty wins) and each clip gets its `caption`. The copy+hash runs off the main actor in a single read
  pass (`LibraryStore.copyComputingDigest`) and clips are saved in batches.
  Because the copies are the original bytes (not re-encoded), their `sourceHash`
  matches the export, so these clips are reconstructable from it.
- `Exporter.swift` — builds an `AVMutableComposition` from the month's clips
  in date order (then createdAt), inserting each clip's in→out range. Photos
  are first rendered (cropped, via AVAssetWriter) into silent temp MP4
  segments of their display duration, then inserted like videos. **Card clips**
  (`cardID` set) have no file: the card is rendered fresh from its current
  document (on the main actor, in the same pass that collects clip URLs) and the
  resulting image is written into a segment the same way (a card whose card was
  since deleted is skipped). Per-
  segment `AVMutableVideoCompositionInstruction` aspect-fits each clip into
  the render size (handles preferredTransform / rotated iPhone video,
  letterboxes mixed orientations). Exports MP4 via `AVAssetExportSession`,
  highest quality, 30fps frameDuration. `buildComposition` also takes an
  optional `fadeInSeconds`/`fadeOutSeconds` (the per-period bookend fades, when
  no cover/ending card): the **fade-in** ramps the first clip's opacity up from
  black (+ its audio + date stamp), the **fade-out** ramps the last segment's
  opacity to black, the audio volume to 0 (`AVMutableAudioMix`) and the date
  stamp to 0 — each skipped if that clip already fades itself. The `audioMix`
  and the date `dateOverlays`' fade fields carry the same spans so preview and
  export stay in sync (the preview dims its SwiftUI stamp over the same ranges).
  After the clip loop (which records each clip's placed `segmentByClipID`
  range), an **audio-track pass** lays each `clip.audio` onto its *own*
  composition audio track — so it mixes with the clips' own audio and keeps
  playing over silent photo segments. Positions come from
  `store.timelineLayout()` — the **project-wide global render order** (all clips,
  durations from metadata, photos floored to 0.5s), shared with the Soundtrack
  view — not just the clips in this render: each track's span comes from the
  layout's resolved `tracks` (offset + end reference, stale references
  repaired, overlapping spans clamped). The rendered clips are grouped into
  globally-contiguous **runs** —
  a plain range render is one run; a tag filter (or a failed insert) splits
  them — and each run maps global→local time with its own constant, every
  fragment clamped inside its run's actual CMTime range (Double↔CMTime drift
  otherwise leaves the composition's tail uncovered → black picture). So **a
  track that started on an earlier day/month is picked up mid-file** (a
  single-day "Preview Day" included), a track spanning a filtered-out gap cuts
  and resumes mid-file like the picture does, and only songs whose span
  overlaps a run get their asset opened at all. A negative offset skips into
  the file; it plays once (silent tail if the file is shorter than the span).
  Every placed song gets an `AVMutableAudioMixInputParameters` envelope
  (volume, its own fades at its true start/end — and the render's bookend
  fade-in/out ramps the music with the picture; a clip fading mid-video
  doesn't), folded into the same `audioMix`. Preview and export need no
  further work — `MonthComposition.audioMix` already flows to both.

## Conventions & constraints

- Swift / SwiftUI only, no third-party dependencies, no ffmpeg.
- Minimum deployment: macOS 14. Use modern async AVFoundation APIs
  (`load(.duration)`, `loadTracks(withMediaType:)`, `generator.image(at:)`).
- App Sandbox is ON; User Selected File = Read/Write. Use
  `startAccessingSecurityScopedResource()` for imported URLs. Project folders
  live anywhere the user picks, so access is regained across launches via
  security-scoped bookmarks (`.withSecurityScope`), not raw paths.
- Keep it simple — this is a personal tool, not a product. Prefer fewer
  features that work over configurability.
- After any change, build with `xcodebuild -scheme ClipDiary build` and fix
  errors before finishing.

## Versioning

ClipDiary uses semantic versioning (`MAJOR.MINOR.PATCH`), tracked in the
Xcode project's `MARKETING_VERSION` build setting (both Debug and Release
configs in `ClipDiary.xcodeproj/project.pbxproj`) and mirrored in
`CHANGELOG.md`. Started at `1.0.0`.

**Every PR bumps the version and adds a CHANGELOG.md entry**, as part of
that PR:
- **PATCH** — bug fixes, small tweaks, no new user-visible capability.
- **MINOR** — new features, additive changes (the common case).
- **MAJOR** — breaking changes, e.g. a project/data format change that isn't
  backward compatible, or a significant rework of how the app is used.

`CHANGELOG.md` entries are written for a human reading what's new, not as a
commit log: a short, plain-language summary of what changed, under a new
`## [x.y.z] - YYYY-MM-DD` heading at the top (after the intro).

## Known state

v1 is working: import, calendar, trim, preview, month export all functional.
The app is **project-based**: launching with no remembered project shows a
welcome screen (New / Open / Recent); the last-used project reopens
automatically. The calendar/import/export all operate on the open project.
Per-project **settings** (`settings.json`) hold the render orientation
(portrait/landscape — chosen once here, no longer asked per export/preview); the
toolbar's **Project Settings** sheet (⌘,) edits it and also hosts source-folder
management. Cover/Ending cards, their fades, and their display durations —
including the first-clip fade-in / last-clip fade-out used when a side is None —
live per render period in the Create Video window, not in Project Settings.
**Cards** (designed title frames, managed in the Cards window) are used three
ways — Cover, Ending, or a clip on a day — and every use is a **live
reference**: the card is re-rendered from its current document at preview/export
time, so editing a card updates everywhere it's used on the next render. A card
itself no longer stores a duration: a day placement keeps its own (editable in
the photo editor) and a Cover/Ending sets one in the Create Video window. The
card editor shows a **"Where it's used"** panel (cover/ending periods + days)
via `LibraryStore.cardUsage(of:)`, so the blast radius of an edit is visible
before changing it (period labels come from `RenderRange(periodKey:)`, the
inverse of `periodKey`).
The main screen has a tag filter (toolbar picker, single tag) that scopes the
calendar thumbnails/counts and the rendered video. A single **Create Video…**
toolbar button opens `RenderSheet`, where a time range (a specific month, a
specific year, everything, or a custom start–end) is chosen — defaulting to the
current month and remembered per project — then previewed in a window or saved
to a file.
The month render shows a 1SE-style date stamp ("MAR 03 2026") bottom-left,
per-clip toggle (`Clip.showsDateOverlay`, "Date stamp" checkbox in both
editors); 1SE imports default it off (their frames are already stamped).
Export burns it in via `AVVideoCompositionCoreAnimationTool`; the preview
window draws the same stamp as a synced SwiftUI overlay, sized by the shared
`DateStamp` constants in Models.swift.
The primary population flow is **source folders + the day window**: each
project lists folders (e.g. the month's photo dump) scanned recursively into a
chronological index; opening a day shows that day's media as a thumbnail rail
alongside its already-picked clips. Reviewing a source (↑/↓ navigate, crossing
into later days; ⌘↩ adds the trimmed/cropped draft and advances) and editing a
picked clip happen in the same window. Source files are copied into `Clips/`
only when picked. The old Import menu still works for one-off files.

## Backup / reconstruction

A clip's edits (trim/crop/tags/date/caption) all live in `clips.json` — the
media files in `Clips/` are never modified. So backing up `clips.json` (plus
`settings.json` / `sources.json`) captures everything except the raw media
bytes. Each clip records `sourceHash` (SHA-256) + `sourceBytes` of its copied
file (`LibraryStore.contentDigest`), so a lost `Clips/` folder can later be
rebuilt: hash the user's source files, match each clip's `sourceHash`, and
re-copy the match to `Clips/<fileName>`. **Reconstruction is not yet
implemented** — only the data needed for it is stored, going forward (clips
made before this field carry `sourceHash == nil`). Clips whose bytes have no
source-folder counterpart — 1SE imports (re-encoded per-day MP4s) and one-off
`importMedia` files — store a hash for integrity but can't be reconstructed.
**Card clips** (`cardID` set) have no media bytes at all (no `sourceHash`):
they render from the card document under `Cards/<id>/`, so backing up the
`Cards/` folder alongside `clips.json` preserves them. **Audio tracks**
(`clip.audio`) reference copied files in the project's `Audio/` folder (no
`sourceHash` either), so back up `Audio/` alongside `Clips/`.

## Roadmap ideas (not yet built)

- Drag-and-drop video files directly onto a calendar day.
- Keyboard nudging of trim handles (arrow keys, frame-by-frame).
- Year view and a "best of the year" export.

