import SwiftUI

@main
struct ClipDiaryApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .commands {
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
                PreviewWindow(range: request.range, tagFilter: request.tagFilter,
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

/// Help-menu item that opens the keyboard-shortcuts window. A small view so it
/// can reach `openWindow` from the environment inside the commands builder.
private struct ShortcutsHelpButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("ClipDiary Keyboard Shortcuts") { openWindow(id: "shortcuts") }
            .keyboardShortcut("/", modifiers: .command)
    }
}
