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
  durationSeconds, createdAt, tags, kind, crop) + date/time helpers. A clip is
  a video or a photo (`ClipKind`); photos store their display duration in
  durationSeconds/outSeconds and an optional `CropRect` (unit coords, top-left
  origin). Trim/crop are metadata only; media files are never modified
  (non-destructive). Tags are free-form multi-word strings, deduped
  case-insensitively.
- `LibraryStore.swift` — `@MainActor ObservableObject`. Owns the **currently
  open project**: a user-chosen directory (e.g. `~/MyClips/Amelie's life/`)
  holding `clips.json` (ISO-8601 dates) + a `Clips/` subfolder of copied media.
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
  in — crop coords are always relative to the oriented image).
- `ContentView.swift` — month calendar grid (LazyVGrid, 7 columns, respects
  `calendar.firstWeekday`), day cells with thumbnails and clip-count badges,
  toolbar with an Import menu (Import Media… fileImporter multi-select,
  Import 1SE Video…) and Export Month.
  Also contains `ExportSheet` (portrait 1080×1920 / landscape 1920×1080
  picker, NSSavePanel, progress bar).
- `TrimView.swift` — `DaySheet` (per-day editor, clip picker if a day has
  multiple clips, routes to `TrimEditor` or `PhotoEditor` by kind, date
  reassignment, delete), `TagRow` (shared tag chips + new-tag field + reuse
  menu) and `TrimSlider` (filmstrip of 10 thumbnails with draggable yellow
  in/out handles, min gap 0.1s). Set In/Set Out buttons (⌘I/⌘O) mark trim
  points at the current playback time. "Preview Trim" plays exactly the
  in→out segment using a periodic time observer to pause at the out point.
- `PhotoView.swift` — `PhotoEditor` (crop, display-duration stepper, aspect
  lock picker Free/16:9/9:16, tags, date, delete) and `PhotoCropView`
  (aspect-fit photo, draggable yellow corner handles + move-inside gesture,
  min crop 5%; an aspect lock snaps the crop and constrains corner drags).
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
  highest quality, 30fps frameDuration.

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

## Known state

v1 is working: import, calendar, trim, preview, month export all functional.
The app is **project-based**: launching with no remembered project shows a
welcome screen (New / Open / Recent); the last-used project reopens
automatically. The calendar/import/export all operate on the open project.
The main screen has a tag filter (toolbar picker, single tag) that scopes the
calendar thumbnails/counts and the month export.
The month render shows a 1SE-style date stamp ("MAR 03 2026") bottom-left,
per-clip toggle (`Clip.showsDateOverlay`, "Date stamp" checkbox in both
editors); 1SE imports default it off (their frames are already stamped).
Export burns it in via `AVVideoCompositionCoreAnimationTool`; the preview
window draws the same stamp as a synced SwiftUI overlay, sized by the shared
`DateStamp` constants in Models.swift.

## Roadmap ideas (not yet built)

- Drag-and-drop video files directly onto a calendar day.
- Keyboard nudging of trim handles (arrow keys, frame-by-frame).
- Background music track for the monthly export.
- Year view and a "best of the year" export.

