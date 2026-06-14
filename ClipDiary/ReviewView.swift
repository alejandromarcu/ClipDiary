import SwiftUI
import AppKit
import AVFoundation

/// Identifies which day a review window starts at.
struct ReviewRequest: Codable, Hashable {
    let day: Date
}

/// Steps through the source folders' photos and videos in capture order,
/// starting at a chosen day. ↓/↑ move to the next/previous item — running
/// past the end of a day just continues into the next day that has media.
/// Files with no embedded capture date sit in an **undated bucket** after
/// the last dated day (guessing from filesystem dates would pin them to the
/// download day); their drafts default to the clicked day and get an orange
/// badge as a reminder to set the real day before adding.
/// The embedded editor trims/crops/tags the current item; ⌘↩ adds it to the
/// library and moves on. The same video can be added several times with
/// different trims. A strip at the bottom shows what the current day already
/// has, with a shortcut to its editor.
struct ReviewWindow: View {
    @EnvironmentObject var store: LibraryStore
    let startDay: Date

    /// id of the item under review; nil before positioning or past the end.
    @State private var currentID: String?
    /// True once navigation ran past the last item.
    @State private var reachedEnd = false
    /// Draft clip for the current item (built async — videos need their
    /// duration loaded before the trim slider makes sense).
    @State private var draft: Clip?
    /// The item the current `draft` was built for. The editor is only shown
    /// when this matches `currentID`: navigating to a new item re-renders the
    /// body before `buildDraft` refreshes `draft`, and seeding an editor with
    /// the previous item's draft would leak its kind/duration into the new
    /// clip (e.g. a photo saved as a video).
    @State private var draftItemID: String?
    @State private var draftError: String?
    /// For a Live Photo, whether the user chose its motion video over the
    /// still. Reset to the still each time a new item comes up.
    @State private var useMotion = false
    /// Day whose picked clips are being edited in a sheet.
    @State private var editDay: DaySelection?
    @State private var showSources = false

    private var items: [SourceItem] { store.sourceItems }

    private var currentIndex: Int? {
        guard let currentID else { return nil }
        return items.firstIndex { $0.id == currentID }
    }

    private var current: SourceItem? { currentIndex.map { items[$0] } }

    private var canGoPrevious: Bool {
        if reachedEnd { return !items.isEmpty }
        guard let idx = currentIndex else { return false }
        return idx > 0
    }

    private var undatedCount: Int { items.filter(\.isUndated).count }

    var body: some View {
        VStack(spacing: 12) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PickedStrip(day: current?.captureDate?.dayKey ?? startDay.dayKey) {
                editDay = DaySelection(day: $0)
            }
        }
        .padding(16)
        .frame(minWidth: 700, idealWidth: 840, maxWidth: .infinity,
               minHeight: 640, idealHeight: 780, maxHeight: .infinity)
        .navigationTitle("Review — \(store.currentProjectName ?? "ClipDiary")")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { previous() } label: {
                    Label("Previous", systemImage: "chevron.up")
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!canGoPrevious)
                .help("Previous photo/video (↑)")
                Button { next() } label: {
                    Label("Next", systemImage: "chevron.down")
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(current == nil)
                .help("Next photo/video — skips into the following day at the end of a day (↓)")
            }
        }
        .sheet(item: $editDay) { selection in
            DaySheet(day: selection.day).environmentObject(store)
        }
        .sheet(isPresented: $showSources) {
            SourceFoldersSheet().environmentObject(store)
        }
        .onAppear { ensurePosition() }
        .onChange(of: store.sourceItems) { _, _ in ensurePosition() }
        // Rebuild when the item changes or the Live Photo still/motion choice
        // flips — the draft is a photo or a video clip accordingly. Both state
        // changes in one navigation batch into a single rebuild.
        .task(id: DraftRequest(itemID: currentID, motion: useMotion)) { await buildDraft() }
    }

    /// Identity of the draft to build: which item, and (Live Photos) whether
    /// to use the motion video instead of the still.
    private struct DraftRequest: Hashable {
        let itemID: String?
        let motion: Bool
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                if let item = current {
                    Text(subheadline(for: item))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let item = current {
                if item.isUndated {
                    Label("No capture date", systemImage: "calendar.badge.exclamationmark")
                        .font(.callout.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.orange.opacity(0.15)))
                        .help("This file carries no date (often stripped by chat apps) — pick the day below before adding")
                }
                if item.isLivePhoto {
                    Label("Live Photo", systemImage: "livephoto")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .help("Add this as the still image, or switch to its short motion video below")
                }
                let used = store.usageCount(of: item)
                if used > 0 {
                    Text(used == 1 ? "Added ✓" : "Added ✓ ×\(used)")
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.green.opacity(0.25)))
                }
            }
            Spacer()
            if store.isScanningSources {
                ProgressView().controlSize(.small)
                Text("Scanning…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if undatedCount > 0 && current?.isUndated != true {
                Button {
                    jumpToUndated()
                } label: {
                    Label("\(undatedCount) undated", systemImage: "calendar.badge.exclamationmark")
                }
                .help("Jump to the photos and videos without a capture date (reviewed after all dated days)")
            }
            Button {
                showSources = true
            } label: {
                Label("Sources…", systemImage: "folder.badge.gearshape")
            }
            .help("Manage the folders scanned for photos and videos")
        }
    }

    private var headline: String {
        if let item = current {
            if let date = item.captureDate {
                return date.formatted(date: .complete, time: .omitted)
            }
            return "Undated photos & videos"
        }
        if reachedEnd { return "No more photos or videos" }
        return startDay.formatted(date: .complete, time: .omitted)
    }

    /// "3 of 14 today · IMG_0041.JPG · 4:47 PM" — or the undated equivalent.
    private func subheadline(for item: SourceItem) -> String {
        if let date = item.captureDate {
            return "\(positionInDay(of: item)) · \(item.fileName) · \(date.formatted(date: .omitted, time: .shortened))"
        }
        let undated = items.filter(\.isUndated)
        let position = (undated.firstIndex(of: item) ?? 0) + 1
        return "\(position) of \(undated.count) undated · \(item.fileName)"
    }

    /// e.g. "3 of 14 today". Dated items only.
    private func positionInDay(of item: SourceItem) -> String {
        guard let date = item.captureDate else { return "" }
        let dayItems = items.filter { $0.captureDate?.isSameDay(as: date) == true }
        let position = (dayItems.firstIndex(of: item) ?? 0) + 1
        return "\(position) of \(dayItems.count) today"
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasProject {
            ContentUnavailableView("No project open", systemImage: "folder")
        } else if store.sourceFolders.isEmpty {
            ContentUnavailableView {
                Label("No source folders yet", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Point ClipDiary at the folder where you gather this project's photos and videos, then click a calendar day to review them.")
            } actions: {
                Button("Add Source Folders…") { showSources = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if let item = current {
            if let draftError {
                ContentUnavailableView {
                    Label("Can't open this file", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(draftError)
                } actions: {
                    Button("Skip to Next") { next() }
                }
            } else if let draft, draftItemID == item.id {
                editor(for: item, draft: draft)
                    .id(useMotion ? "\(item.id)#motion" : item.id)
            } else {
                ProgressView("Loading \(item.fileName)…")
            }
        } else if store.isScanningSources {
            ProgressView("Scanning source folders…")
        } else if items.isEmpty {
            ContentUnavailableView(
                "No photos or videos found",
                systemImage: "photo.on.rectangle.angled",
                description: Text("The source folders don't contain any media ClipDiary recognizes.")
            )
        } else {
            ContentUnavailableView {
                Label("You're caught up", systemImage: "checkmark.circle")
            } description: {
                Text("No more photos or videos on or after this day — press ↑ to step back.")
            } actions: {
                Button("Back to Previous (↑)") { previous() }
                    .disabled(!canGoPrevious)
            }
        }
    }

    /// The trim/photo editor for the current item. Live Photos get a
    /// segmented control to choose the still or the motion video; the rest of
    /// the editor (and the draft) follows that choice.
    @ViewBuilder
    private func editor(for item: SourceItem, draft: Clip) -> some View {
        VStack(spacing: 10) {
            if item.isLivePhoto {
                Picker("", selection: $useMotion) {
                    Text("Photo").tag(false)
                    Text(motionLabel(for: item)).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("This is a Live Photo — add it as the still image, or use its short motion video")
            }

            if useMotion, let motion = item.motionURL {
                TrimEditor(clip: draft, sourceURL: motion) { add($0) }
            } else if item.kind == .photo {
                PhotoEditor(clip: draft, sourceURL: item.url) { add($0) }
            } else {
                TrimEditor(clip: draft, sourceURL: item.url) { add($0) }
            }
        }
    }

    /// "Video · 0:03" when the motion length is known, else "Video".
    private func motionLabel(for item: SourceItem) -> String {
        if let duration = item.duration {
            return "Video · \(formatDurationShort(duration))"
        }
        return "Video"
    }

    // MARK: - Navigation

    /// Puts the cursor on the first item of `startDay` (or the next day that
    /// has media; failing that, the undated bucket at the end). Re-run when
    /// the index changes — e.g. the initial scan finishing after the window
    /// opened, or a rescan dropping the current item.
    private func ensurePosition() {
        if let currentID, items.contains(where: { $0.id == currentID }) { return }
        if reachedEnd { return }
        currentID = items.first { ($0.captureDate ?? .distantFuture) >= startDay.dayKey }?.id
        if currentID == nil && !items.isEmpty && !store.isScanningSources {
            reachedEnd = true
        }
    }

    /// Jumps to the first item of the undated bucket.
    private func jumpToUndated() {
        guard let id = items.first(where: \.isUndated)?.id else { return }
        useMotion = false
        currentID = id
        reachedEnd = false
    }

    private func next() {
        guard let idx = currentIndex else { return }
        useMotion = false
        if idx + 1 < items.count {
            currentID = items[idx + 1].id
        } else {
            currentID = nil
            reachedEnd = true
        }
    }

    private func previous() {
        useMotion = false
        if reachedEnd {
            currentID = items.last?.id
            reachedEnd = false
            return
        }
        guard let idx = currentIndex, idx > 0 else { return }
        currentID = items[idx - 1].id
    }

    private func add(_ clip: Clip) {
        guard let item = current else { return }
        // A Live Photo added as its motion copies the video, not the still.
        let source = (useMotion && item.isLivePhoto) ? item.motionURL : nil
        store.pick(item, draft: clip, from: source)
        next()
    }

    // MARK: - Draft

    private func buildDraft() async {
        draft = nil
        draftItemID = nil
        draftError = nil
        guard let item = current else { return }
        // Undated items default to the clicked day — the badge reminds the
        // user to set the real one in the editor's date picker.
        let day = (item.captureDate ?? startDay).dayKey

        // A plain video, or a Live Photo the user switched to its motion clip,
        // builds a video draft from that file; otherwise it's a photo draft.
        let videoURL: URL? = item.kind == .video ? item.url
            : (item.isLivePhoto && useMotion ? item.motionURL : nil)

        if let videoURL {
            let asset = AVURLAsset(url: videoURL)
            guard let duration = try? await asset.load(.duration).seconds,
                  duration.isFinite, duration > 0 else {
                if !Task.isCancelled {
                    draftError = "\(videoURL.lastPathComponent) doesn't look like a playable video."
                }
                return
            }
            guard !Task.isCancelled else { return }
            draft = Clip(
                fileName: "",
                date: day,
                outSeconds: duration,
                durationSeconds: duration
            )
            draftItemID = item.id
        } else {
            draft = Clip(
                fileName: "",
                date: day,
                outSeconds: LibraryStore.defaultPhotoDuration,
                durationSeconds: LibraryStore.defaultPhotoDuration,
                kind: .photo
            )
            draftItemID = item.id
        }
    }
}

// MARK: - Picked strip

/// Thumbnails of the clips already picked for a day; clicking one (or the
/// Edit button) opens the day's regular clip editor.
private struct PickedStrip: View {
    @EnvironmentObject var store: LibraryStore
    let day: Date
    var onEdit: (Date) -> Void

    private var dayClips: [Clip] { store.clips(on: day) }

    var body: some View {
        HStack(spacing: 8) {
            Text(dayClips.isEmpty ? "Nothing picked for this day yet" : "Picked for this day:")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(dayClips) { clip in
                        PickedThumb(clip: clip)
                            .onTapGesture { onEdit(day) }
                            .help("Edit this day's clips")
                    }
                }
            }
            if !dayClips.isEmpty {
                Button("Edit Day…") { onEdit(day) }
                    .help("Open this day's clip editor")
            }
        }
        .frame(height: 44)
    }
}

private struct PickedThumb: View {
    @EnvironmentObject var store: LibraryStore
    let clip: Clip

    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.black.opacity(0.15)
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(formatTime(clip.trimmedDuration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .padding(3)
        }
        .task(id: clip.thumbnailKey) { image = await store.thumbnail(for: clip) }
    }
}

// MARK: - Source folders sheet

/// Manage the project's source folders — the folders scanned recursively for
/// the photos and videos offered in the review window.
/// The source-folder list with its add / rescan / status controls, without any
/// surrounding chrome. Used both as a standalone sheet (`SourceFoldersSheet`,
/// auto-presented for a fresh project) and as a section of Project Settings.
struct SourceFoldersSection: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ClipDiary scans these folders (subfolders included) for photos and videos. Click a calendar day to review them — a file is only copied into the project when you add it to your clips.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.sourceFolders.isEmpty {
                ContentUnavailableView(
                    "No source folders",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Add the folder where you gather this month's photos and videos.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(store.sourceFolders) { folder in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name)
                            Text(folder.url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            store.removeSourceFolder(folder)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("Remove this folder from the project's sources (files on disk are untouched)")
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 160, maxHeight: 240)
            }

            HStack {
                Button {
                    presentAddSourceFolderPanel(store: store)
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Button {
                    store.rescanSources()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(store.sourceFolders.isEmpty || store.isScanningSources)
                .help("Pick up files added to the source folders since the last scan")
                Spacer()
                if store.isScanningSources {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                } else if !store.sourceFolders.isEmpty {
                    let undated = store.sourceItems.filter(\.isUndated).count
                    Text(undated > 0
                         ? "\(store.sourceItems.count) photos & videos · \(undated) without a date"
                         : "\(store.sourceItems.count) photos & videos")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }
}

struct SourceFoldersSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source Folders")
                .font(.title3.bold())
            SourceFoldersSection()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Open-panel flow for adding source folders (multi-select).
@MainActor
func presentAddSourceFolderPanel(store: LibraryStore) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add"
    panel.message = "Choose folders containing this project's photos and videos."
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
        store.addSourceFolder(url)
    }
}
