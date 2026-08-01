import SwiftUI
import Combine
import Sparkle

@main
struct ClipDiaryApp: App {
    @StateObject private var store = LibraryStore()

    // Sparkle auto-updater: starting it on launch enables the scheduled
    // background checks; the menu item below triggers manual ones.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { presentNewProjectPanel(store: store) }
                    .keyboardShortcut("n")
                Button("Open Project…") { presentOpenProjectPanel(store: store) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Open Recent") {
                    let recents = store.recentProjects
                    ForEach(recents) { recent in
                        Button(recent.name) { store.openFromBookmark(recent.bookmark) }
                    }
                    if !recents.isEmpty {
                        Divider()
                        Button("Clear Menu") { store.clearRecentProjects() }
                    }
                }
                .disabled(store.recentProjects.isEmpty)
            }
            // Replace the dead default "ClipDiary Help" (there's no help book)
            // with the keyboard-shortcuts cheat sheet — the standard macOS home
            // for "how do I learn the shortcuts".
            CommandGroup(replacing: .help) {
                ShortcutsHelpButton()
            }
        }

        // Month preview opens in its own (resizable) window — sheets on
        // macOS can't be resized by the user.
        WindowGroup("Preview", for: PreviewRequest.self) { $request in
            if let request {
                PreviewWindow(range: request.range,
                              includeBookends: request.includeBookends)
                    .environmentObject(store)
            }
        }

        // Interacting with a calendar day opens the day window: flip through the
        // source folders' photos/videos to add clips, and edit the day's
        // already-picked clips — both in one place.
        WindowGroup("Day", for: ReviewRequest.self) { $request in
            if let request {
                ReviewWindow(startDay: request.day, startUndated: request.startUndated,
                             focusSources: request.focusSources,
                             startClipID: request.startClipID)
                    .environmentObject(store)
            }
        }

        // The background-audio timeline ("Soundtrack"): the project's clips on a
        // time axis with a draggable audio lane beneath. Opened from the calendar
        // toolbar, seeded with the day to scroll to.
        WindowGroup("Soundtrack", for: SoundtrackRequest.self) { $request in
            if let request {
                SoundtrackView(anchorDate: request.anchorDate,
                               selectTrackID: request.selectTrackID)
                    .environmentObject(store)
            }
        }

        // The Cards gallery + editor in its own resizable window (opened with
        // openWindow(id: "cards") from the calendar toolbar).
        WindowGroup("Cards", id: "cards") {
            CardsManagerView()
                .environmentObject(store)
        }

        // The keyboard-shortcuts cheat sheet, a single shared window opened from
        // the Help menu or ⌘/.
        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// App-menu "Check for Updates…" backed by Sparkle. Disabled while a check is
/// already in progress, tracked via Sparkle's `canCheckForUpdates` KVO.
private struct CheckForUpdatesButton: View {
    let updater: SPUUpdater
    @State private var canCheck = true

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheck)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}

/// Help-menu item that opens the keyboard-shortcuts window. A small view so it
/// can reach `openWindow` from the environment inside the commands builder.
private struct ShortcutsHelpButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("ClipDiary Keyboard Shortcuts") { openWindow(id: "shortcuts") }
            .keyboardShortcut("/", modifiers: .command)
    }
}
