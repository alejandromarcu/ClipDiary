import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

/// Sheet for one calendar day: pick a clip (if several), preview it,
/// drag the in/out handles to trim, change its date, or delete it.
struct DaySheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let day: Date

    @State private var selectedClipID: UUID?
    @State private var showCardPicker = false

    private var dayClips: [Clip] { store.clips(on: day) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(day.formatted(date: .complete, time: .omitted))
                    .font(.headline)
                Spacer()
                Button {
                    showCardPicker = true
                } label: {
                    Label("Add Card…", systemImage: "rectangle.on.rectangle.angled")
                }
                .help("Add a designed title card as a clip on this day")
                if !dayClips.isEmpty {
                    Button("Preview Day") {
                        openWindow(value: PreviewRequest(
                            range: .custom(start: day, end: day), tagFilter: nil,
                            includeEndingFade: false, includeBookends: false))
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if dayClips.count > 1 {
                DayClipStrip(day: day, clips: dayClips, selectedClipID: $selectedClipID)
            }

            if let clip = dayClips.first(where: { $0.id == selectedClipID }) ?? dayClips.first {
                if clip.kind == .photo {
                    PhotoEditor(clip: clip)
                        .id(clip.id)
                } else {
                    TrimEditor(clip: clip)
                        .id(clip.id)
                }
            } else {
                ContentUnavailableView(
                    "No clip on this day",
                    systemImage: "video.slash",
                    description: Text("Import a video and set its date to add one.")
                )
                .frame(minHeight: 200)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .background(ResizableSheetSupport(minSize: NSSize(width: 640, height: 560)))
        .onAppear { selectedClipID = dayClips.first?.id }
        .sheet(isPresented: $showCardPicker) {
            CardsManagerView(onPick: { store.addCard($0, to: day) })
                .environmentObject(store)
        }
    }
}

/// SwiftUI sheets on macOS are created without the `.resizable` window style,
/// so flexible frames alone don't let the user drag the sheet's edges. Once
/// resizable, the window also stops honoring SwiftUI's min frame, so the
/// minimum has to be set on the window itself.
private struct ResizableSheetSupport: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = minSize
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Horizontal strip of the day's clips, in play order (left → right). Click a
/// thumbnail to edit it; drag one onto another to reorder, so clips can run out
/// of strict capture order when that makes for nicer transitions. Shown only
/// when a day has more than one clip; replaces the old segmented clip picker.
private struct DayClipStrip: View {
    @EnvironmentObject var store: LibraryStore
    let day: Date
    let clips: [Clip]
    @Binding var selectedClipID: UUID?

    /// id of the clip currently being dragged (the drop target reads it to
    /// compute the new order). Cleared on drop.
    @State private var draggingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drag to reorder · click to edit")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        cell(index: index, clip: clip)
                    }
                }
                .padding(.vertical, 2)
            }
            .animation(.snappy(duration: 0.2), value: clips.map(\.id))
        }
    }

    private func cell(index: Int, clip: Clip) -> some View {
        let isSelected = (selectedClipID ?? clips.first?.id) == clip.id
        return VStack(spacing: 3) {
            StripThumb(clip: clip)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                )
            Text("Clip \(index + 1)")
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedClipID = clip.id }
        .onDrag {
            draggingID = clip.id
            return NSItemProvider(object: clip.id.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in reorder(onto: clip) }
        .help("Click to edit · drag to reorder")
    }

    /// Moves the dragged clip to where `target` sits and commits the new order.
    private func reorder(onto target: Clip) -> Bool {
        defer { draggingID = nil }
        guard let draggingID, draggingID != target.id,
              let from = clips.firstIndex(where: { $0.id == draggingID }),
              let to = clips.firstIndex(where: { $0.id == target.id })
        else { return false }
        var order = clips
        order.insert(order.remove(at: from), at: to)
        store.reorderClips(on: day, orderedIDs: order.map(\.id))
        return true
    }
}

/// Fixed-size thumbnail of a clip (its in-point frame or the cropped photo)
/// with its trimmed length, for the day editor's reorder strip.
private struct StripThumb: View {
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
            .frame(width: 84, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 2) {
                Image(systemName: clip.kind == .photo ? "photo" : "video")
                Text(formatTime(clip.trimmedDuration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(3)
        }
        .task(id: clip.thumbnailKey) { image = await store.thumbnail(for: clip) }
    }
}

/// Editable row of tag chips with a field for new tags and a menu to reuse
/// tags already in the library. Used by both the video and photo editors.
struct TagRow: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var tags: [String]
    @State private var newTag = ""

    /// Tags used elsewhere in the library but not yet on this clip.
    private var reusableTags: [String] {
        store.allTags.filter { tag in
            !tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
            if tags.isEmpty {
                Text("No tags")
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
            }
            TextField("New tag", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit { addTag(newTag) }
            Menu {
                ForEach(reusableTags, id: \.self) { tag in
                    Button(tag) { addTag(tag) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .fixedSize()
            .disabled(reusableTags.isEmpty)
            .help("Add an existing tag")
        }
    }

    private func addTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        newTag = ""
    }
}

/// Day chooser that shows the date as a button opening a calendar popover —
/// the convenient picker, without the compact picker's up/down steppers.
/// Shared by the video and photo editors.
struct DayPickerField: View {
    @Binding var selection: Date
    @State private var showingPicker = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Day")
            Button {
                showingPicker.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(selection.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                DatePicker("Day", selection: $selection, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
                    .frame(width: 280)
            }
        }
    }
}

/// The actual trim UI for a single clip. Two modes: editing a library clip
/// (auto-saves on disappear, can delete), or reviewing a source video — the
/// clip is a draft, `sourceURL` points at the original file, and an "Add to
/// Clips" button hands the configured draft to `onAdd`.
struct TrimEditor: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State var clip: Clip
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var thumbnails: [NSImage] = []
    @State private var isPlayingPreview = false
    @State private var playheadSeconds = 0.0
    @State private var editedDate: Date

    /// Snapshot as the editor opened, for Revert.
    private let original: Clip
    private let sourceURL: URL?
    private let onAdd: ((Clip) -> Void)?

    init(clip: Clip, sourceURL: URL? = nil, onAdd: ((Clip) -> Void)? = nil) {
        original = clip
        self.sourceURL = sourceURL
        self.onAdd = onAdd
        _clip = State(initialValue: clip)
        _editedDate = State(initialValue: clip.date)
    }

    private var isReview: Bool { onAdd != nil }

    private var hasChanges: Bool {
        clip != original || editedDate.dayKey != original.date
    }

    var body: some View {
        VStack(spacing: 14) {
            if let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            TrimSlider(
                duration: clip.durationSeconds,
                inSeconds: $clip.inSeconds,
                outSeconds: $clip.outSeconds,
                playheadSeconds: playheadSeconds,
                thumbnails: thumbnails,
                onScrub: { seconds in seek(to: seconds) }
            )
            .frame(height: 56)

            HStack {
                Button {
                    setInPoint()
                } label: {
                    Label("Set In", systemImage: "arrow.right.to.line")
                }
                .keyboardShortcut("i", modifiers: [])
                .help("Mark the current playback time as the start of the trim (I)")
                Text(formatTime(clip.inSeconds))
                Spacer()
                Button {
                    isPlayingPreview ? stopPreview() : playTrimmedPreview()
                } label: {
                    Label(isPlayingPreview ? "Stop" : "Preview Trim",
                          systemImage: isPlayingPreview ? "stop.fill" : "play.fill")
                }
                Text("Length: \(formatTime(clip.trimmedDuration))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(clip.outSeconds))
                Button {
                    setOutPoint()
                } label: {
                    Label("Set Out", systemImage: "arrow.left.to.line")
                }
                .keyboardShortcut("o", modifiers: [])
                .help("Mark the current playback time as the end of the trim (O)")
            }
            .font(.callout.monospacedDigit())
            // Keep the keyboard skip shortcuts even though the on-screen
            // Back/Forward buttons were removed.
            .background {
                HStack {
                    Button("Back \(Int(skipStep))s") { skip(by: -skipStep) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("Forward \(Int(skipStep))s") { skip(by: skipStep) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .hidden()
            }

            TagRow(tags: $clip.tags)

            HStack(spacing: 8) {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.secondary)
                TextField("Caption (optional)", text: $clip.caption)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            HStack {
                DayPickerField(selection: $editedDate)
                Toggle("Date stamp", isOn: $clip.showsDateOverlay)
                    .toggleStyle(.checkbox)
                    .help("Show this clip's date in the bottom-left corner of the month video. Turn off for 1SE imports (already stamped) or cover clips.")
                Spacer()
                Button {
                    stopPreview()
                    clip = original
                    editedDate = original.date
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .disabled(!hasChanges)
                .help("Discard this clip's unsaved changes")
                if let onAdd {
                    Button {
                        stopPreview()
                        var added = clip
                        added.date = editedDate.dayKey
                        onAdd(added)
                    } label: {
                        Label("Add to Clips", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Add this trimmed segment to the day's clips (⌘↩)")
                } else {
                    Button(role: .destructive) {
                        stopPreview()
                        store.delete(clip)
                        dismiss()
                    } label: {
                        Label("Delete Clip", systemImage: "trash")
                    }
                }
            }
        }
        .onAppear { setUp() }
        .task { await loadThumbnails(url: sourceURL ?? store.fileURL(for: clip)) }
        .onDisappear {
            // Auto-save so switching clips or closing the sheet keeps edits.
            // No-op if the clip was just deleted. Review drafts aren't in the
            // library, so there's nothing to save.
            if !isReview { saveEdits() }
            tearDown()
        }
        .onChange(of: clip.inSeconds) { _, newValue in seek(to: newValue) }
        .onChange(of: clip.outSeconds) { _, newValue in seek(to: newValue) }
    }

    private func saveEdits() {
        var updated = clip
        updated.date = editedDate.dayKey
        store.update(updated)
    }

    // MARK: - In/out marking

    /// Same minimum in→out gap the slider enforces.
    private let minGap = 0.1

    private func setInPoint() {
        guard let now = currentPlayerSeconds else { return }
        clip.inSeconds = min(max(0, now), clip.outSeconds - minGap)
    }

    private func setOutPoint() {
        guard let now = currentPlayerSeconds else { return }
        clip.outSeconds = max(min(clip.durationSeconds, now), clip.inSeconds + minGap)
    }

    /// How far the back/forward buttons (← / →) jump.
    private let skipStep: Double = 5

    /// Seek relative to the current playback time, clamped to the clip bounds.
    private func skip(by delta: Double) {
        guard let now = currentPlayerSeconds else { return }
        if isPlayingPreview { stopPreview() }
        let target = min(max(0, now + delta), clip.durationSeconds)
        seek(to: target)
    }

    private var currentPlayerSeconds: Double? {
        guard let player else { return nil }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    // MARK: - Player

    private func setUp() {
        let url = sourceURL ?? store.fileURL(for: clip)
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        seek(to: clip.inSeconds)

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { time in
            if time.seconds.isFinite { playheadSeconds = time.seconds }
            if isPlayingPreview && time.seconds >= clip.outSeconds {
                stopPreview()
            }
        }
    }

    private func tearDown() {
        stopPreview()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
    }

    private func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    private func playTrimmedPreview() {
        seek(to: clip.inSeconds)
        player?.play()
        isPlayingPreview = true
    }

    private func stopPreview() {
        player?.pause()
        isPlayingPreview = false
    }

    private func loadThumbnails(url: URL) async {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let count = 10
        var images: [NSImage] = []
        for i in 0..<count {
            if Task.isCancelled { return }
            let seconds = clip.durationSeconds * (Double(i) + 0.5) / Double(count)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let (cg, _) = try? await generator.image(at: time) {
                images.append(NSImage(cgImage: cg, size: .zero))
            }
        }
        thumbnails = images
    }
}

/// Thumbnail filmstrip with draggable in/out handles.
struct TrimSlider: View {
    let duration: Double
    @Binding var inSeconds: Double
    @Binding var outSeconds: Double
    var playheadSeconds: Double = 0
    let thumbnails: [NSImage]
    var onScrub: (Double) -> Void

    private let handleWidth: CGFloat = 12
    private let minGap = 0.1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let inX = position(of: inSeconds, width: width)
            let outX = position(of: outSeconds, width: width)

            ZStack(alignment: .leading) {
                // Filmstrip
                HStack(spacing: 0) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: max(1, width / CGFloat(max(1, thumbnails.count))),
                                   height: geo.size.height)
                            .clipped()
                    }
                }
                .frame(width: width, height: geo.size.height)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Dimmed (cut) regions
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, inX), height: geo.size.height)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, width - outX), height: geo.size.height)
                    .offset(x: outX)

                // Selection border
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(handleWidth * 2, outX - inX), height: geo.size.height)
                    .offset(x: inX)

                // Playhead (current playback position)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: geo.size.height)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(x: position(of: playheadSeconds, width: width) - 1)
                    .allowsHitTesting(false)

                // In handle
                handle()
                    .offset(x: inX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let seconds = time(at: value.location.x, width: width)
                                inSeconds = min(max(0, seconds), outSeconds - minGap)
                                onScrub(inSeconds)
                            }
                    )

                // Out handle
                handle()
                    .offset(x: outX - handleWidth)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let seconds = time(at: value.location.x, width: width)
                                outSeconds = max(min(duration, seconds), inSeconds + minGap)
                                onScrub(outSeconds)
                            }
                    )
            }
        }
    }

    private func handle() -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: handleWidth)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(.black.opacity(0.5))
                    .frame(width: 2, height: 18)
            )
            .contentShape(Rectangle().inset(by: -8))
    }

    private func position(of seconds: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(seconds / duration) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x), width) / width) * duration
    }
}
