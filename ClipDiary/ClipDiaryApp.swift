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
                              includeEndingFade: request.includeEndingFade,
                              includeBookends: request.includeBookends)
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

        // Editing a calendar day opens its own window (instead of a sheet) so
        // it remembers its position and size between openings, like Review.
        WindowGroup("Edit Day", for: DayEditRequest.self) { $request in
            if let request {
                DaySheet(day: request.day)
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
