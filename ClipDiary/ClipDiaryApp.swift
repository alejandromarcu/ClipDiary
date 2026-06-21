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
    }
}
