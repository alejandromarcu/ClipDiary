import SwiftUI
import AppKit
import AVFoundation

/// Identifies which day the day window opens on. `startUndated` opens it
/// straight on the undated bucket instead (used by the calendar's "undated"
/// button); `day` is still carried as the fallback day for those items.
/// `focusSources` lands on the day's source media (the + circle) rather than
/// its already-picked clips (a plain cell click) — both open the same window.
struct ReviewRequest: Codable, Hashable {
    let day: Date
    var startUndated: Bool = false
    var focusSources: Bool = false
}

/// The day window: one place to both **review** a day's source photos/videos
/// and **edit** the clips already picked for it.
///
/// A left rail lists the day's content as thumbnails in two sections — *Picked*
/// (the clips already added: click to edit, drag to reorder, delete from the
/// editor) and *From sources* (every source item captured that day: click to
/// review and add). Selecting a picked clip shows the library editor; selecting
/// a source item shows the review editor with "Add to Clips" (⌘↩).
///
/// ↑/↓ navigate within whichever section is active. The source flow runs past
/// the end of a day into the next day that has media and finally an **undated
/// bucket** (files with no embedded capture date — guessing a day from the
/// filesystem would pin them to the download day); their drafts default to the
/// window's day and get an orange warning.
struct ReviewWindow: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let startDay: Date
    /// Open directly on the undated bucket (from the calendar's undated button).
    var startUndated = false
    /// Prefer the day's source media over its picked clips for the initial
    /// selection (the calendar's + circle).
    var focusSources = false

    /// What the editor on the right currently shows.
    private enum Selection: Hashable {
        case clip(UUID)         // an already-picked clip on `currentDay`
        case source(String)     // a source item (id is its file path)
    }

    @State private var selection: Selection?
    /// The day the rail (and any undated draft's default date) is anchored to.
    /// Follows a dated source item's day as the source flow crosses days.
    @State private var currentDay: Date
    /// True once the source flow ran past the last item.
    @State private var reachedEnd = false

    /// Draft clip for the selected source item (built async — videos need their
    /// duration loaded before the trim slider makes sense).
    @State private var draft: Clip?
    /// The source item the current `draft` was built for; the source editor is
    /// only shown when this matches the selection so a stale draft can't leak
    /// its kind/duration into a freshly selected item.
    @State private var draftItemID: String?
    @State private var draftError: String?
    /// For a Live Photo, whether the user chose its motion video over the still.
    @State private var useMotion = false

    /// Holds the picked-clip editor's latest in-flight edit so "Preview Day" can
    /// flush it before opening the preview (editors only persist on disappear).
    @State private var liveEdits = LiveEditBuffer()
    /// id of the picked clip being dragged in the rail (the drop target reads it
    /// to compute the new order). Cleared on drop.
    @State private var draggingClipID: UUID?

    @State private var showSources = false
    @State private var showCardPicker = false

    init(startDay: Date, startUndated: Bool = false, focusSources: Bool = false) {
        self.startDay = startDay
        self.startUndated = startUndated
        self.focusSources = focusSources
        _currentDay = State(initialValue: startDay.dayKey)
    }

    private var sourceItems: [SourceItem] { store.sourceItems }

    private var selectedSourceID: String? {
        if case .source(let id) = selection { return id }
        return nil
    }
    private var selectedSource: SourceItem? {
        selectedSourceID.flatMap { id in sourceItems.first { $0.id == id } }
    }
    private var selectedClipID: UUID? {
        if case .clip(let id) = selection { return id }
        return nil
    }

    private var dayClips: [Clip] { store.clips(on: currentDay) }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        }
        .frame(minWidth: 1000, idealWidth: 1180, maxWidth: .infinity,
               minHeight: 600, idealHeight: 780, maxHeight: .infinity)
        // Esc closes the window, matching the app's other windows.
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .navigationTitle(currentDay.formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            // All navigation lives in the toolbar: day-stepping then item-stepping.
            ToolbarItemGroup(placement: .navigation) {
                Button { goToDay(forward: false) } label: {
                    Label("Previous Day", systemImage: "chevron.backward")
                }
                .disabled(store.adjacentContentDay(from: currentDay, forward: false) == nil)
                .help("Previous day with photos, videos or clips (<)")
                .keyboardShortcut(",", modifiers: .shift)
                Button { goToDay(forward: true) } label: {
                    Label("Next Day", systemImage: "chevron.forward")
                }
                .disabled(store.adjacentContentDay(from: currentDay, forward: true) == nil)
                .help("Next day with photos, videos or clips (>)")
                .keyboardShortcut(".", modifiers: .shift)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { previous() } label: {
                    Label("Previous", systemImage: "chevron.up")
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!canGoPrevious)
                .help("Previous item in this section (↑)")
                Button { next() } label: {
                    Label("Next", systemImage: "chevron.down")
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!canGoNext)
                .help("Next item — the source flow continues into the following day at the end of a day (↓)")
            }
        }
        .sheet(isPresented: $showSources) {
            SourceFoldersSheet().environmentObject(store)
        }
        .sheet(isPresented: $showCardPicker) {
            CardsManagerView(onPick: { doc in
                store.addCard(doc, to: currentDay)
                if let added = dayClips.last { selection = .clip(added.id) }
            })
            .environmentObject(store)
        }
        .onAppear { ensurePosition() }
        .onChange(of: store.sourceItems) { _, _ in ensurePosition() }
        // Rebuild the source draft when the item changes or the Live Photo
        // still/motion choice flips.
        .task(id: DraftRequest(itemID: selectedSourceID, motion: useMotion)) { await buildDraft() }
    }

    /// Identity of the source draft to build: which item, and (Live Photos)
    /// whether to use the motion video instead of the still.
    private struct DraftRequest: Hashable {
        let itemID: String?
        let motion: Bool
    }

    /// Orange warning shown above the media for an undated source item.
    private var undatedBadge: some View {
        Label("No capture date", systemImage: "calendar.badge.exclamationmark")
            .font(.callout.bold())
            .foregroundStyle(.orange)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.orange.opacity(0.15)))
            .help("This file carries no date (often stripped by chat apps) — set the day in the editor before adding")
    }

    // MARK: - Rail

    /// The left column represents the whole day: its content (picked + available)
    /// in a scrolling list, with the day-scoped actions pinned at the bottom.
    private var rail: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pickedSection
                        sourcesSection
                    }
                    // Extra leading room so the content clears the window edge,
                    // and trailing room so the scrollbar doesn't crowd the
                    // thumbnails.
                    .padding(.leading, 16)
                    .padding(.trailing, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Keep the selected thumbnail in view as ↑/↓ walks past the fold.
                .onChange(of: selection) { _, sel in
                    guard let sel else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(sel, anchor: .center)
                    }
                }
            }
            Divider()
            railFooter
        }
        .frame(width: 210)
    }

    /// Day-scoped actions + scan status, pinned below the rail list.
    private var railFooter: some View {
        VStack(spacing: 8) {
            if store.isScanningSources {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Button { showCardPicker = true } label: {
                Label("Add Card…", systemImage: "rectangle.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .help("Add a designed title card as a clip on this day")
            Button { previewDay() } label: {
                Label("Preview Day", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(dayClips.isEmpty)
            .help("Play this day's clips in a preview window")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var pickedSection: some View {
        let clips = dayClips
        return VStack(alignment: .leading, spacing: 6) {
            railHeader("Picked", count: clips.count)
            if clips.isEmpty {
                Text("Nothing picked yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(clips) { clip in
                    RailClipThumb(clip: clip, isSelected: selectedClipID == clip.id)
                        .id(Selection.clip(clip.id))
                        .onTapGesture { selection = .clip(clip.id) }
                        .onDrag {
                            draggingClipID = clip.id
                            return NSItemProvider(object: clip.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], isTargeted: nil) { _ in reorder(onto: clip, in: clips) }
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        // While reviewing an undated item, the section becomes the undated
        // bucket; otherwise it's the current day's source media.
        let undatedMode = selectedSource?.isUndated == true
        let items = undatedMode ? sourceItems.filter(\.isUndated) : store.sourceItems(on: currentDay)
        VStack(alignment: .leading, spacing: 6) {
            railHeader(undatedMode ? "Undated" : "Available", count: items.count)
            if items.isEmpty {
                Text(undatedMode ? "No undated media" : "No source media on this day")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items) { item in
                    RailSourceThumb(item: item,
                                    isSelected: selectedSourceID == item.id,
                                    usage: store.usageCount(of: item))
                        .id(Selection.source(item.id))
                        .onTapGesture { selectSource(item) }
                }
            }
        }
    }

    private func railHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    /// Moves the dragged picked clip to where `target` sits and commits the new
    /// play order for the day.
    private func reorder(onto target: Clip, in clips: [Clip]) -> Bool {
        defer { draggingClipID = nil }
        guard let draggingClipID, draggingClipID != target.id,
              let from = clips.firstIndex(where: { $0.id == draggingClipID }),
              let to = clips.firstIndex(where: { $0.id == target.id })
        else { return false }
        var order = clips
        order.insert(order.remove(at: from), at: to)
        store.reorderClips(on: currentDay, orderedIDs: order.map(\.id))
        return true
    }

    // MARK: - Content (the editor)

    @ViewBuilder
    private var content: some View {
        if !store.hasProject {
            ContentUnavailableView("No project open", systemImage: "folder")
        } else if store.sourceFolders.isEmpty && dayClips.isEmpty {
            ContentUnavailableView {
                Label("No source folders yet", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Point ClipDiary at the folder where you gather this project's photos and videos, then pick a calendar day to review them — or add a title card.")
            } actions: {
                Button("Add Source Folders…") { showSources = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch selection {
            case .clip(let id):
                if let clip = dayClips.first(where: { $0.id == id }) {
                    clipEditor(clip)
                } else {
                    emptyState
                }
            case .source(let id):
                if let item = sourceItems.first(where: { $0.id == id }) {
                    sourceEditor(item)
                } else {
                    emptyState
                }
            case .none:
                emptyState
            }
        }
    }

    /// Library-mode editor for an already-picked clip.
    @ViewBuilder
    private func clipEditor(_ clip: Clip) -> some View {
        if clip.kind == .photo {
            PhotoEditor(clip: clip, onLiveEdit: { liveEdits.clip = $0 },
                        onDelete: { deleteClip(clip) })
                .id(clip.id)
        } else {
            TrimEditor(clip: clip, onLiveEdit: { liveEdits.clip = $0 },
                       onDelete: { deleteClip(clip) })
                .id(clip.id)
        }
    }

    /// Review-mode editor for a source item: trims/crops a draft and adds it.
    @ViewBuilder
    private func sourceEditor(_ item: SourceItem) -> some View {
        if let draftError {
            ContentUnavailableView {
                Label("Can't open this file", systemImage: "exclamationmark.triangle")
            } description: {
                Text(draftError)
            } actions: {
                Button("Skip to Next") { next() }
            }
        } else if let draft, draftItemID == item.id {
            // An undated warning and/or the Live Photo still/motion picker ride
            // above the media so they don't push the metadata pane down.
            let accessory = sourceAccessory(for: item)
            Group {
                if useMotion, let motion = item.motionURL {
                    TrimEditor(clip: draft, sourceURL: motion, onAdd: { add($0) },
                               reviewInfo: reviewInfo(for: item), mediaAccessory: accessory)
                } else if item.kind == .photo {
                    PhotoEditor(clip: draft, sourceURL: item.url, onAdd: { add($0) },
                                reviewInfo: reviewInfo(for: item), mediaAccessory: accessory)
                } else {
                    TrimEditor(clip: draft, sourceURL: item.url, onAdd: { add($0) },
                               reviewInfo: reviewInfo(for: item), mediaAccessory: accessory)
                }
            }
            .id(useMotion ? "\(item.id)#motion" : item.id)
        } else {
            ProgressView("Loading \(item.fileName)…")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.isScanningSources {
            ProgressView("Scanning source folders…")
        } else if reachedEnd {
            ContentUnavailableView {
                Label("You're caught up", systemImage: "checkmark.circle")
            } description: {
                Text("No more photos or videos on or after this day — press ↑ to step back.")
            } actions: {
                Button("Back to Previous (↑)") { previous() }
                    .disabled(!canGoPrevious)
            }
        } else {
            ContentUnavailableView {
                Label("Nothing on this day", systemImage: "calendar")
            } description: {
                Text("No picked clips or source media here. Use Add Card… above, or pick another day.")
            }
        }
    }

    /// The stack shown above the media for a source item: an undated warning
    /// and/or the Live Photo still/motion picker. nil when neither applies.
    private func sourceAccessory(for item: SourceItem) -> AnyView? {
        guard item.isUndated || item.isLivePhoto else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                if item.isUndated { undatedBadge }
                if item.isLivePhoto { livePhotoPicker(for: item) }
            }
        )
    }

    /// "Live Photo" label + the still/motion segmented control.
    private func livePhotoPicker(for item: SourceItem) -> some View {
        HStack(spacing: 8) {
            Label("Live Photo", systemImage: "livephoto")
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $useMotion) {
                Text("Photo").tag(false)
                Text(motionLabel(for: item)).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("This is a Live Photo — add it as the still image, or use its short motion video")
        }
        .font(.callout)
    }

    /// The time/file context shown atop the source editor's metadata pane. The
    /// day is the window title, so only the capture time is repeated here.
    private func reviewInfo(for item: SourceItem) -> ReviewItemInfo {
        if let date = item.captureDate {
            let time = date.formatted(date: .omitted, time: .shortened)
            return ReviewItemInfo(
                title: time,
                detailLines: [positionInDay(of: item), item.fileName]
            )
        }
        let undated = sourceItems.filter(\.isUndated)
        let position = (undated.firstIndex(of: item) ?? 0) + 1
        return ReviewItemInfo(
            title: "Undated",
            detailLines: ["\(position) of \(undated.count) undated", item.fileName]
        )
    }

    /// e.g. "3 of 14 today". Dated items only.
    private func positionInDay(of item: SourceItem) -> String {
        guard let date = item.captureDate else { return "" }
        let dayItems = sourceItems.filter { $0.captureDate?.isSameDay(as: date) == true }
        let position = (dayItems.firstIndex(of: item) ?? 0) + 1
        return "\(position) of \(dayItems.count) today"
    }

    /// "Video · 0:03" when the motion length is known, else "Video".
    private func motionLabel(for item: SourceItem) -> String {
        if let duration = item.duration {
            return "Video · \(formatDurationShort(duration))"
        }
        return "Video"
    }

    // MARK: - Navigation

    private var canGoPrevious: Bool {
        switch selection {
        case .clip(let id):
            return (dayClips.firstIndex { $0.id == id } ?? 0) > 0
        case .source(let id):
            return (sourceItems.firstIndex { $0.id == id } ?? 0) > 0
        case .none:
            return reachedEnd && !sourceItems.isEmpty
        }
    }

    private var canGoNext: Bool {
        switch selection {
        case .clip(let id):
            guard let i = dayClips.firstIndex(where: { $0.id == id }) else { return false }
            return i + 1 < dayClips.count
        case .source(let id):
            guard let i = sourceItems.firstIndex(where: { $0.id == id }) else { return false }
            return i + 1 < sourceItems.count
        case .none:
            return false
        }
    }

    private func next() {
        switch selection {
        case .clip(let id):
            let clips = dayClips
            if let i = clips.firstIndex(where: { $0.id == id }), i + 1 < clips.count {
                selection = .clip(clips[i + 1].id)
            }
        case .source(let id):
            if let i = sourceItems.firstIndex(where: { $0.id == id }), i + 1 < sourceItems.count {
                selectSource(sourceItems[i + 1])
            } else {
                selection = nil
                reachedEnd = true
            }
        case .none:
            break
        }
    }

    private func previous() {
        switch selection {
        case .clip(let id):
            let clips = dayClips
            if let i = clips.firstIndex(where: { $0.id == id }), i > 0 {
                selection = .clip(clips[i - 1].id)
            }
        case .source(let id):
            if let i = sourceItems.firstIndex(where: { $0.id == id }), i > 0 {
                selectSource(sourceItems[i - 1])
            }
        case .none:
            if reachedEnd, let last = sourceItems.last { selectSource(last) }
        }
    }

    /// Selects a source item, resetting the Live Photo choice and following its
    /// day so the rail tracks the source flow across days.
    private func selectSource(_ item: SourceItem) {
        useMotion = false
        reachedEnd = false
        selection = .source(item.id)
        if let date = item.captureDate { currentDay = date.dayKey }
    }

    /// Steps the window to the previous/next day that has content, flushing any
    /// in-flight edit and selecting that day's picks or sources (per
    /// `focusSources`). Positions directly rather than via `ensurePosition` so it
    /// never falls back to the undated bucket. The target always has content
    /// (that's how `adjacentContentDay` chose it).
    private func goToDay(forward: Bool) {
        guard let day = store.adjacentContentDay(from: currentDay, forward: forward) else { return }
        if let edited = liveEdits.clip { store.update(edited) }
        liveEdits.clip = nil
        reachedEnd = false
        currentDay = day
        let picks = dayClips
        let firstSource = store.sourceItems(on: currentDay).first
        if focusSources {
            if !select(firstSource) { _ = select(picks.first) }
        } else {
            if !select(picks.first) { _ = select(firstSource) }
        }
    }

    /// Puts the cursor somewhere sensible: the undated bucket if requested, then
    /// the day's picked clips or source media (order depends on `focusSources`),
    /// then the next day that has media. Re-run when the scan finishes or a
    /// rescan drops the current item.
    private func ensurePosition() {
        if let selection, isValid(selection) { return }
        if reachedEnd { return }

        if startUndated, let undated = sourceItems.first(where: \.isUndated) {
            selectSource(undated)
            return
        }

        let picks = dayClips
        let firstSource = store.sourceItems(on: currentDay).first
        let preferred: [() -> Bool] = focusSources
            ? [{ select(firstSource) }, { select(picks.first) }]
            : [{ select(picks.first) }, { select(firstSource) }]
        for attempt in preferred where attempt() { return }

        // Nothing on this day: flow to the next day that has source media.
        if let onward = sourceItems.first(where: {
            ($0.captureDate ?? .distantFuture) >= currentDay.dayKey
        }) {
            selectSource(onward)
            return
        }
        if !sourceItems.isEmpty && !store.isScanningSources {
            selection = nil
            reachedEnd = true
        }
    }

    /// Helper for `ensurePosition`: selects the given clip/source if present and
    /// reports whether it did.
    private func select(_ clip: Clip?) -> Bool {
        guard let clip else { return false }
        selection = .clip(clip.id)
        return true
    }
    private func select(_ item: SourceItem?) -> Bool {
        guard let item else { return false }
        selectSource(item)
        return true
    }

    private func isValid(_ sel: Selection) -> Bool {
        switch sel {
        case .clip(let id): return dayClips.contains { $0.id == id }
        case .source(let id): return sourceItems.contains { $0.id == id }
        }
    }

    // MARK: - Actions

    private func add(_ clip: Clip) {
        guard let item = selectedSource else { return }
        // A Live Photo added as its motion copies the video, not the still.
        let source = (useMotion && item.isLivePhoto) ? item.motionURL : nil
        store.pick(item, draft: clip, from: source)
        next()
    }

    /// Deletes a picked clip and selects the previous clip, then the next, then
    /// the day's first source — keeping the window open instead of closing.
    private func deleteClip(_ clip: Clip) {
        let clips = dayClips
        var neighborID: UUID?
        if let idx = clips.firstIndex(where: { $0.id == clip.id }) {
            if idx > 0 {
                neighborID = clips[idx - 1].id
            } else if idx + 1 < clips.count {
                neighborID = clips[idx + 1].id
            }
        }
        // Don't re-flush the just-deleted clip from the live-edit buffer.
        if liveEdits.clip?.id == clip.id { liveEdits.clip = nil }
        store.delete(clip)
        if let neighborID {
            selection = .clip(neighborID)
        } else if let firstSource = store.sourceItems(on: currentDay).first {
            selectSource(firstSource)
        } else {
            selection = nil
        }
    }

    private func previewDay() {
        // Flush the editor's unsaved edits first so the preview reflects them.
        if let edited = liveEdits.clip { store.update(edited) }
        openWindow(value: PreviewRequest(
            range: .custom(start: currentDay, end: currentDay), tagFilter: nil,
            includeBookends: false))
    }

    // MARK: - Source draft

    private func buildDraft() async {
        draft = nil
        draftItemID = nil
        draftError = nil
        guard let item = selectedSource else { return }
        // Undated items default to the window's day — the badge reminds the user
        // to set the real one in the editor's date picker.
        let day = (item.captureDate ?? currentDay).dayKey

        // A plain video, or a Live Photo switched to its motion clip, builds a
        // video draft from that file; otherwise it's a photo draft.
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
            let photoDuration = store.settings.lastPhotoDuration
            draft = Clip(
                fileName: "",
                date: day,
                outSeconds: photoDuration,
                durationSeconds: photoDuration,
                kind: .photo
            )
            draftItemID = item.id
        }
    }
}

// MARK: - Rail thumbnails

/// Fixed-size thumbnail of a picked clip in the day window's rail, with a
/// selection ring and its kind + trimmed length.
private struct RailClipThumb: View {
    @EnvironmentObject var store: LibraryStore
    let clip: Clip
    let isSelected: Bool

    @State private var image: NSImage?

    var body: some View {
        RailThumbBox(image: image, isSelected: isSelected) {
            HStack(spacing: 2) {
                Image(systemName: clip.kind == .photo ? "photo" : "video")
                Text(formatTime(clip.trimmedDuration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(4)
        }
        .help("Click to edit · drag to reorder")
        .task(id: clip.thumbnailKey) { image = await store.thumbnail(for: clip) }
    }
}

/// Thumbnail of a not-yet-picked source item in the rail, with an "Added ✓×n"
/// badge when it's already been used and a Live Photo marker.
private struct RailSourceThumb: View {
    @EnvironmentObject var store: LibraryStore
    let item: SourceItem
    let isSelected: Bool
    let usage: Int

    @State private var image: NSImage?

    var body: some View {
        RailThumbBox(image: image, isSelected: isSelected) {
            HStack(spacing: 2) {
                Image(systemName: item.isLivePhoto ? "livephoto"
                      : (item.kind == .photo ? "photo" : "video"))
                if let duration = item.duration {
                    Text(formatDurationShort(duration))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(4)
        } topTrailing: {
            if usage > 0 {
                Text(usage == 1 ? "✓" : "✓×\(usage)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.green.opacity(0.9)))
                    .padding(4)
            }
        }
        .help(item.fileName)
        .task(id: item.id) { image = await store.thumbnail(for: item) }
    }
}

/// Shared rail thumbnail container: a fixed 16:9 box with the image (or a
/// placeholder), a selection ring, and caller-supplied bottom-leading and
/// top-trailing overlays.
private struct RailThumbBox<BottomLeading: View, TopTrailing: View>: View {
    let image: NSImage?
    let isSelected: Bool
    @ViewBuilder var bottomLeading: BottomLeading
    @ViewBuilder var topTrailing: TopTrailing

    init(image: NSImage?, isSelected: Bool,
         @ViewBuilder bottomLeading: () -> BottomLeading,
         @ViewBuilder topTrailing: () -> TopTrailing = { EmptyView() }) {
        self.image = image
        self.isSelected = isSelected
        self.bottomLeading = bottomLeading()
        self.topTrailing = topTrailing()
    }

    var body: some View {
        ZStack {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.black.opacity(0.15)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )
            .overlay(alignment: .bottomLeading) { bottomLeading }
            .overlay(alignment: .topTrailing) { topTrailing }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Source folders sheet

/// Manage the project's source folders — the folders scanned recursively for
/// the photos and videos offered in the day window.
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
