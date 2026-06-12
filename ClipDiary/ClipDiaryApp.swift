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
                PreviewWindow(month: request.month, tagFilter: request.tagFilter)
                    .environmentObject(store)
            }
        }

        // Clicking a calendar day opens the review window: flip through the
        // source folders' photos/videos and pick the day's keepers.
        WindowGroup("Review", for: ReviewRequest.self) { $request in
            if let request {
                ReviewWindow(startDay: request.day)
                    .environmentObject(store)
            }
        }
    }
}
