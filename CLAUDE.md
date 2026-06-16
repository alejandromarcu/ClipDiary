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
  + Clear Menu.
- `Models.swift` — `Clip` struct (id, fileName, date, inSeconds, outSeconds,
  durationSeconds, createdAt, tags, kind, crop, sourcePath, sourceHash,
  sourceBytes) + date/time helpers. (`id` is a random `UUID`, not a content
  hash.) A clip is a video or a photo (`ClipKind`); photos store their
  display duration in durationSeconds/outSeconds and an optional `CropRect`
  (unit coords, top-left origin). Trim/crop are metadata only; media files are
  never modified (non-destructive). Tags are free-form multi-word strings,
  deduped case-insensitively. `sourcePath` records which source-folder file a
  clip was picked from: clips picked twice from one source (two segments of a
  long video) **share one copied media file**, so `delete` only removes the
  file when the last clip referencing it goes. `sourceHash` (lowercase-hex
  SHA-256 of the copied media bytes) + `sourceBytes` (file size) are recorded at
  pick/import time so the project can be rebuilt by content if `Clips/` is lost
  — see "Backup / reconstruction" below. Also `ProjectSettings`
  (orientation + ending-fade toggle/duration + the remembered Create Video
  `renderRange`): a small per-project Codable blob, every field defaulted via
  `decodeIfPresent` so old projects and future options need no migration. And
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
  ImageIO (photos). `importMedia` routes by UTType. Imported clips default to the recording
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
- `ReviewView.swift` — `ReviewWindow` (opened by clicking a calendar day):
  steps through `sourceItems` in capture order starting at that day, ↑/↓ for
  previous/next (flowing into following days and finally the undated
  bucket), embeds `TrimEditor`/`PhotoEditor` in review mode on a per-item
  draft clip, "Add to Clips" (⌘↩) calls `store.pick` and auto-advances;
  "Added ✓ ×n" badge via `usageCount(of:)`. Undated items show an orange
  "No capture date" badge, their drafts default to the clicked day, and an
  "N undated" header button jumps to the bucket. A **Live Photo** shows a
  "Photo / Video" segmented picker (`useMotion`): Photo embeds `PhotoEditor`
  on the still, Video embeds `TrimEditor` on the motion clip; ⌘↩ then picks
  whichever (copying the still or the motion file). Bottom strip shows the
  day's picked clips and opens `DaySheet` to edit them. Also
  `SourceFoldersSheet` (a thin wrapper around the reusable
  `SourceFoldersSection`: add/remove/rescan source folders; auto-presented
  when a project has no clips and no sources) and
  `presentAddSourceFolderPanel`.
- `ContentView.swift` — month calendar grid (week-row `VStack`/`HStack`s, 7
  columns, respects `calendar.firstWeekday`) that fills the window height with
  hairline cell borders so cells grow when the window does. Day cells show a
  thumbnail + picked-clip badge and a source-availability footer (video count
  + length, photo count from `store.availability(on:)`); the month header
  carries the same month-wide tally.
  **Clicking a day opens the review window** (`ReviewRequest` via openWindow);
  the per-day clip editor (`DaySheet`) is on the day cell's context menu and
  in the review window's picked strip. Toolbar: a **Project Settings** gear
  (⌘,), an Import menu (Import Media… fileImporter multi-select, Import 1SE
  Video…) and a single **Create Video…** button. Also contains
  `ProjectSettingsSheet` (orientation radio group, ending-fade toggle + duration
  stepper, and a `SourceFoldersSection`) and `RenderSheet` — the unified
  Preview/Export window: a time-range picker (`RenderMode` month/year/all/custom,
  remembered in `settings.renderRange`, defaulting to the current month) with
  **Preview** (opens `PreviewWindow`) and **Save…** (NSSavePanel + progress bar)
  buttons, plus a video/photo count (calendar `video.fill`/`photo.fill` icons)
  and total length for the chosen range; format/fade still come from Project
  Settings (no longer surfaced in this window).
- `TrimView.swift` — `DaySheet` (per-day editor; when a day has multiple clips
  a `DayClipStrip` shows them as a thumbnail row in play order — click to edit,
  **drag one onto another to reorder** (via `LibraryStore.reorderClips`) so
  clips can run out of chronological order for nicer transitions; routes to
  `TrimEditor` or `PhotoEditor` by kind, date reassignment, delete), `TagRow`
  (shared tag chips + new-tag field + reuse
  menu) and `TrimSlider` (filmstrip of 10 thumbnails with draggable yellow
  in/out handles, min gap 0.1s). Set In/Set Out buttons (⌘I/⌘O) mark trim
  points at the current playback time. "Preview Trim" plays exactly the
  in→out segment using a periodic time observer to pause at the out point.
  `TrimEditor` has two modes: library (auto-saves on disappear, can delete)
  and **review** (`sourceURL:` plays the original source file, `onAdd:` shows
  an "Add to Clips" ⌘↩ button handing back the configured draft).
- `PhotoView.swift` — `PhotoEditor` (crop, display-duration stepper, aspect
  lock picker Free/16:9/9:16, tags, date, delete) and `PhotoCropView`
  (aspect-fit photo, draggable yellow corner handles + move-inside gesture,
  min crop 5%; an aspect lock snaps the crop and constrains corner drags).
  Same library/review modes as `TrimEditor`.
- `MashImport.swift` — "Import 1SE Video": splits a mashed 1 Second Everyday
  export into per-day clips by OCR'ing (Vision) the date stamp burned into
  the bottom-left corner ("MAR 03 2026"). Coarse 0.3s sampling pass, then
  bisection refines each day boundary to ~1 frame; each day's range is
  re-encoded to its own MP4 (`AVAssetExportSession`, frame-accurate) and
  registered via `LibraryStore.adoptVideo(at:date:)`. `MashImportSheet`
  drives scan → review → import phases (reached from the Import toolbar
  menu in `ContentView`).
- `Exporter.swift` — builds an `AVMutableComposition` from the month's clips
  in date order (then createdAt), inserting each clip's in→out range. Photos
  are first rendered (cropped, via AVAssetWriter) into silent temp MP4
  segments of their display duration, then inserted like videos. Per-
  segment `AVMutableVideoCompositionInstruction` aspect-fits each clip into
  the render size (handles preferredTransform / rotated iPhone video,
  letterboxes mixed orientations). Exports MP4 via `AVAssetExportSession`,
  highest quality, 30fps frameDuration. An optional **ending fade**
  (`fadeOutSeconds`, from project settings, clamped to the last clip) ramps the
  last segment's opacity to black, the audio volume to 0 (`AVMutableAudioMix`)
  and the date stamp to 0; `MonthComposition.fadeRange`/`audioMix` carry it so
  preview and export stay in sync (the preview dims its SwiftUI stamp over the
  same range).

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
(portrait/landscape — chosen once here, no longer asked per export/preview) and
an optional ending fade-to-black; the toolbar's **Project Settings** sheet (⌘,)
edits them and also hosts source-folder management.
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
The primary population flow is **source folders + review**: each project
lists folders (e.g. the month's photo dump) scanned recursively into a
chronological index; clicking a day reviews that day's media one by one
(↑/↓ navigate, crossing into later days; ⌘↩ adds the trimmed/cropped draft
and advances). Source files are copied into `Clips/` only when picked. The
old Import menu still works for one-off files.

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

## Roadmap ideas (not yet built)

- Drag-and-drop video files directly onto a calendar day.
- Keyboard nudging of trim handles (arrow keys, frame-by-frame).
- Background music track for the monthly export.
- Year view and a "best of the year" export.

