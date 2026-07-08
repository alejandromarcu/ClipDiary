---
name: verify
description: Build, launch and drive ClipDiary (native SwiftUI macOS app) to verify a change end-to-end.
---

# Verifying ClipDiary changes

## Build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme ClipDiary build
```

(`xcode-select` points at the CLT, so the `DEVELOPER_DIR` prefix is required.)

## Launch

The Debug bundle lands in DerivedData; find it and launch with `open`:

```bash
ls -d ~/Library/Developer/Xcode/DerivedData/ClipDiary-*/Build/Products/Debug/ClipDiary.app
osascript -e 'quit app "ClipDiary"'   # a running instance keeps its old code
open <that .app path>
```

The app reopens the last-used project automatically (security-scoped
bookmark), so it comes up with the user's real library — browsing is safe
(media is never modified; edits only persist via explicit actions).

## Drive

GUI surface → computer-use MCP (`request_access` for "ClipDiary", tier full).
Useful entry points: the toolbar segmented control toggles calendar/timeline;
day cells / timeline clips open the day window; Create Video… opens the
render sheet.

Gotchas learned:
- The user may be actively using the machine — re-screenshot before every
  click; windows move and scroll between captures.
- Synthetic Escape key events from computer-use do not seem to reach the
  app (they failed to close an NSMenu). Don't treat a dead Escape handler
  as an app bug without a manual keyboard check.
- Navigating months persists `lastViewedMonth` in the project's
  settings.json — jumping around during verification changes the user's
  saved spot; consider restoring or telling them.
