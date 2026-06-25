import SwiftUI

// The keyboard-shortcuts cheat sheet (Help ▸ ClipDiary Keyboard Shortcuts, ⌘/).
// ClipDiary leans heavily on the keyboard, and most of its shortcuts are
// context-specific keys bound on buttons inside the day window and editors —
// they never appear in the menu bar, so this window is where they're learned.
//
// `shortcutGroups` is the single source of truth: keep it in step with the
// `.keyboardShortcut` modifiers across the app (ClipDiaryApp, ContentView,
// ReviewView, TrimView, PhotoView).

/// One shortcut: the keys to press (each token drawn as its own key cap) and
/// what it does.
struct ShortcutEntry: Identifiable {
    let id = UUID()
    let keys: [String]
    let label: String
    init(_ keys: [String], _ label: String) {
        self.keys = keys
        self.label = label
    }
}

/// A titled group of shortcuts, matching a place in the app.
struct ShortcutGroup: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let entries: [ShortcutEntry]
    init(_ title: String, subtitle: String? = nil, _ entries: [ShortcutEntry]) {
        self.title = title
        self.subtitle = subtitle
        self.entries = entries
    }
}

let shortcutGroups: [ShortcutGroup] = [
    ShortcutGroup("General", [
        ShortcutEntry(["⌘", "/"], "Show this keyboard shortcuts window"),
    ]),
    ShortcutGroup("Projects", [
        ShortcutEntry(["⌘", "N"], "New project"),
        ShortcutEntry(["⇧", "⌘", "O"], "Open project"),
    ]),
    ShortcutGroup("Calendar", [
        ShortcutEntry(["⌘", ","], "Project settings"),
    ]),
    ShortcutGroup("Day Window", subtitle: "Reviewing a day's photos, videos and clips", [
        ShortcutEntry(["<"], "Previous day with content"),
        ShortcutEntry([">"], "Next day with content"),
        ShortcutEntry(["↑"], "Previous item in the list"),
        ShortcutEntry(["↓"], "Next item (continues into the following day)"),
    ]),
    ShortcutGroup("Trim Editor", subtitle: "Editing a video clip in the day window", [
        ShortcutEntry(["I"], "Set the in point at the playhead"),
        ShortcutEntry(["O"], "Set the out point at the playhead"),
        ShortcutEntry(["Space"], "Play / pause the clip"),
        ShortcutEntry(["P"], "Preview the trimmed in → out segment"),
        ShortcutEntry(["←"], "Skip back 5 seconds"),
        ShortcutEntry(["→"], "Skip forward 5 seconds"),
        ShortcutEntry(["⌘", "↩"], "Add the clip to the day"),
    ]),
    ShortcutGroup("Photo Editor", subtitle: "Editing a photo or card in the day window", [
        ShortcutEntry(["+"], "Show the photo for longer"),
        ShortcutEntry(["−"], "Show the photo for less time"),
        ShortcutEntry(["⌘", "↩"], "Add the photo to the day"),
    ]),
]

struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(shortcutGroups) { group in
                    groupSection(group)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 480, idealHeight: 680)
    }

    private func groupSection(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.headline)
                if let subtitle = group.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    ShortcutRow(entry: entry)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

private struct ShortcutRow: View {
    let entry: ShortcutEntry
    var body: some View {
        HStack(spacing: 12) {
            Text(entry.label)
            Spacer(minLength: 16)
            HStack(spacing: 4) {
                ForEach(Array(entry.keys.enumerated()), id: \.offset) { _, key in
                    KeyCap(key)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A single key drawn as a small rounded "cap", like the keys on a keyboard.
private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}
