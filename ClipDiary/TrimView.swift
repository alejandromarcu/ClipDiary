import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

/// A mutable box for the day window's in-flight clip edits. The embedded
/// trim/photo editors keep their working copy in local `@State` and only write
/// it back to the store on disappear; this lets the day window grab the current
/// copy to persist before opening a preview, without re-rendering on every
/// keystroke. A reference type so the editor can keep it current without
/// re-rendering the host view.
final class LiveEditBuffer {
    var clip: Clip?
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
        // Two rows so the chips and the new-tag field each get a full line —
        // the single-row layout was cramped in the review window's narrow pane.
        VStack(alignment: .leading, spacing: 6) {
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
            }
            HStack(spacing: 8) {
                TextField("New tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
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

/// A music bar shown directly under a clip's own audio in the editors, so laying
/// a song over a clip looks like the rest of the editor. Empty, it reads "＋ Add
/// music" and a click picks a file, laid over this clip (starting at the clip's
/// start, ending at its end) with its waveform drawn in place. Once a track is
/// present the bar is **read-only** for a picked clip — clicking it opens the
/// Soundtrack window for anything finer (offset, span, volume). In **review** (a
/// source not yet added, so it isn't on the timeline and has no Soundtrack entry)
/// the bar instead offers a small ✕ to drop the just-added track, since there's
/// no Soundtrack window to defer to yet. A picked clip reads live from the store,
/// so Soundtrack-window edits show immediately; a review draft reads/writes the
/// draft's `audio` through `draftAudio` and never touches the store's clips.
struct ClipMusicLane: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.openWindow) private var openWindow
    /// The clip (or draft) being edited.
    var clip: Clip
    /// True while reviewing a source not yet added to the day.
    var isReview: Bool
    /// Review mode only: the draft's audio track, written directly (the draft
    /// isn't in the store). Unused for picked clips, which read/write the store.
    @Binding var draftAudio: AudioTrack?

    @State private var showImporter = false
    @State private var waveform: [Float] = []

    private static let audioTypes: [UTType] = [.mp3, .wav, .mpeg4Audio, .aiff, .audio]
    private let laneHeight: CGFloat = 44
    private var accent: Color { .accentColor }

    /// The track that starts on this clip: the draft's in review, the store's
    /// live value for a picked clip.
    private var own: AudioTrack? {
        isReview ? draftAudio : store.clips.first(where: { $0.id == clip.id })?.audio
    }

    /// Music started on an earlier clip that plays over this one — picked clips
    /// only (a review draft isn't on the timeline).
    private var spanning: [ActiveAudioRef] {
        isReview ? [] : store.activeAudio(over: clip)
    }

    var body: some View {
        content
            .frame(height: laneHeight)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Self.audioTypes,
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { add(url) }
            }
            .task(id: own?.fileName) { await loadWaveform() }
    }

    @ViewBuilder
    private var content: some View {
        if own == nil && spanning.isEmpty {
            // Nothing over the clip yet — a plain, full-width prompt.
            addBar
        } else {
            // A song plays over the clip: draw its block aligned to the trimmed
            // [in, out] region so it tracks the yellow handles above — it starts
            // where the clip starts and ends where it ends.
            GeometryReader { geo in
                let width = geo.size.width
                let inX = position(of: clip.inSeconds, width: width)
                let outX = position(of: clip.outSeconds, width: width)
                let blockW = min(width - inX, max(28, outX - inX))
                ZStack(alignment: .leading) {
                    laneBackdrop
                    Group {
                        if let own {
                            filledBar(own)
                        } else if let first = spanning.first {
                            spanningBar(first)
                        }
                    }
                    .frame(width: blockW)
                    .offset(x: inX)
                }
            }
        }
    }

    /// Where `seconds` falls across the lane, using the clip's full length — the
    /// same mapping the trim slider uses, so the block lines up with the handles.
    private func position(of seconds: Double, width: CGFloat) -> CGFloat {
        let d = clip.durationSeconds
        guard d > 0 else { return 0 }
        return CGFloat(min(max(0, seconds / d), 1)) * width
    }

    /// The full-width track lane behind an aligned music block.
    private var laneBackdrop: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06))
            .frame(maxWidth: .infinity)
    }

    // MARK: - Bars

    /// Empty and addable: the whole bar is a button that opens the file picker.
    private var addBar: some View {
        Button { showImporter = true } label: {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary.opacity(0.6))
                .overlay(
                    Label("Add music", systemImage: "music.note")
                        .font(.caption).foregroundStyle(.secondary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Lay a music file over this clip — it starts when the clip starts and ends when it ends. Adjust anything else in the Soundtrack window.")
    }

    /// Music started on this clip: waveform + name, read-only for a picked clip
    /// (tap → Soundtrack); a review draft shows a ✕ to drop it instead.
    private func filledBar(_ track: AudioTrack) -> some View {
        ZStack {
            blockBackground
            WaveformView(samples: waveform, color: accent.opacity(0.7))
                .padding(.top, 18).padding(.bottom, 6).padding(.horizontal, 8)
                .allowsHitTesting(false)
            VStack {
                HStack(spacing: 4) {
                    Label(track.label, systemImage: "music.note")
                        .font(.caption2.weight(.medium)).foregroundStyle(accent)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if isReview {
                        Button { remove() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Remove this music from the clip")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.top, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isReview { openSoundtrack(track.id) } }
        .help(isReview
              ? "Music over this clip. Drop it with ✕, or fine-tune it in the Soundtrack window after adding the clip."
              : "Music over this clip — click to adjust it in the Soundtrack window.")
    }

    /// Music that spans in from an earlier clip (picked clips only): read-only.
    private func spanningBar(_ entry: ActiveAudioRef) -> some View {
        ZStack {
            blockBackground
            VStack {
                VStack(alignment: .leading, spacing: 1) {
                    Label(entry.track.label, systemImage: "music.note")
                        .font(.caption2.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text("Plays from \(entry.startClip.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { openSoundtrack(entry.track.id) }
        .help("Music playing over this clip from an earlier day — click to adjust it in the Soundtrack window.")
    }

    private var blockBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(accent.opacity(0.13))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(accent.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Actions

    /// Copy the picked file and lay a this-clip-only track over the clip. A
    /// picked clip goes through the store (persisted + pruned on replace); a
    /// review draft is written to `draftAudio` and carried into the library by
    /// `pick` when the clip is added.
    private func add(_ url: URL) {
        guard let name = store.copyAudioFile(from: url) else { return }
        let track = AudioTrack(fileName: name, displayName: url.deletingPathExtension().lastPathComponent,
                               endClipID: clip.id)
        if isReview {
            draftAudio = track
        } else {
            store.setAudioTrack(track, onClip: clip.id)
        }
    }

    /// Review only: drop the draft's track and delete its now-unused copy.
    private func remove() {
        guard isReview, let track = draftAudio else { return }
        draftAudio = nil
        store.pruneUnusedAudioFile(track)
    }

    private func openSoundtrack(_ trackID: UUID?) {
        openWindow(value: SoundtrackRequest(anchorDate: clip.date, selectTrackID: trackID))
    }

    private func loadWaveform() async {
        guard let track = own else { waveform = []; return }
        waveform = await loadAudioWaveform(url: store.audioURL(for: track), buckets: 400)
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

/// Library-mode control in the day window's clip editors: copies the picked
/// clip into *another* ClipDiary project ("post to project") — e.g. pulling a
/// clip from a shared main timeline into one child's own project. The menu
/// lists projects copied to recently for one-click reuse, plus
/// "Choose Project…" to navigate to any project folder. A brief confirmation
/// shows after a successful copy.
struct CopyClipToProjectMenu: View {
    @EnvironmentObject var store: LibraryStore
    /// The clip to copy (the editor's current working copy, date applied).
    let clip: Clip
    @State private var confirmation: String?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                let recents = store.recentCopyTargets
                ForEach(recents) { project in
                    Button(project.name) { copy(to: project.url, named: project.name) }
                }
                if !recents.isEmpty { Divider() }
                Button("Choose Project…") {
                    if let url = presentChooseCopyTargetPanel() {
                        copy(to: url, named: url.lastPathComponent)
                    }
                }
            } label: {
                Label("Copy to Project", systemImage: "square.and.arrow.up.on.square")
            }
            .fixedSize()
            .help("Copy this clip into another ClipDiary project (e.g. one child's own timeline)")

            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }
        }
    }

    private func copy(to url: URL, named name: String) {
        guard store.copyClip(clip, toProjectAt: url) else { return }
        withAnimation { confirmation = "Copied to \(name)" }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { confirmation = nil }
        }
    }
}

/// Context block shown atop the review pane: the source item's day plus a few
/// detail lines (its position in the day, file name and time). Built by the
/// review window and handed to the embedded editor so it can sit beside the
/// editing controls instead of in the window's header.
struct ReviewItemInfo: Equatable {
    var title: String
    var detailLines: [String]
}

struct ReviewItemHeader: View {
    let info: ReviewItemInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.title)
                .font(.headline)
            ForEach(info.detailLines, id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A thin vertical divider that resizes the column to its right by dragging.
/// Used between the media and the metadata pane in the review editors; the
/// width it drives is stored in `@AppStorage` so it sticks across items and
/// launches. The pane is on the right, so dragging left widens it.
struct ResizablePaneDivider: View {
    @Binding var width: Double
    var range: ClosedRange<Double> = 220...500

    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                // Wider invisible hit area so the 1px line is easy to grab.
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                width = min(max(range.lowerBound,
                                                base - value.translation.width),
                                            range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
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
    /// A second player for the music laid over this clip (`clip.audio`), so
    /// Preview Trim and Play can be auditioned with the song on top. Synced to
    /// the video and confined to the trimmed [in, out] segment.
    @State private var musicPlayer: AVAudioPlayer?
    @State private var timeObserver: Any?
    @State private var thumbnails: [NSImage] = []
    @State private var waveform: [Float] = []
    /// Whether the player is currently playing (driven by the transport bar's
    /// play button or Preview Trim).
    @State private var isPlaying = false
    /// True while a Preview Trim is running, so playback stops at the out-point
    /// instead of running to the end of the clip.
    @State private var stopAtOut = false
    @State private var playheadSeconds = 0.0
    /// Local key monitor that makes Space toggle play/pause (unless a text field
    /// is being edited). Installed on appear, removed on disappear.
    @State private var spaceKeyMonitor: Any?
    @State private var editedDate: Date
    @State private var showTransition = false
    /// The video's oriented display size, loaded once — the crop box is fit and
    /// aspect-locked to it. Nil until known (the plain player shows meanwhile).
    @State private var videoDisplaySize: CGSize?
    /// Width of the review metadata pane; shared with the photo editor and
    /// remembered across items and launches.
    @AppStorage("reviewPaneWidth") private var paneWidth: Double = 280

    /// Snapshot as the editor opened, for Revert.
    private let original: Clip
    private let sourceURL: URL?
    private let onAdd: ((Clip) -> Void)?
    /// Reports the working copy (date applied) on every change, so the day
    /// editor can persist it before previewing. Library mode only.
    private let onLiveEdit: ((Clip) -> Void)?
    /// Called when the user deletes the clip. When set, the host owns the
    /// deletion (and decides what to show next); otherwise the editor deletes
    /// from the store and dismisses itself. Library mode only.
    private let onDelete: (() -> Void)?
    /// Day/file context shown atop the review pane. Review mode only.
    private let reviewInfo: ReviewItemInfo?
    /// Optional control shown above the media (the Live Photo still/motion
    /// picker), kept in the media column so it doesn't push the pane down.
    private let mediaAccessory: AnyView?

    init(clip: Clip, sourceURL: URL? = nil, onAdd: ((Clip) -> Void)? = nil,
         onLiveEdit: ((Clip) -> Void)? = nil, onDelete: (() -> Void)? = nil,
         reviewInfo: ReviewItemInfo? = nil, mediaAccessory: AnyView? = nil) {
        original = clip
        self.sourceURL = sourceURL
        self.onAdd = onAdd
        self.onLiveEdit = onLiveEdit
        self.onDelete = onDelete
        self.reviewInfo = reviewInfo
        self.mediaAccessory = mediaAccessory
        _clip = State(initialValue: clip)
        _editedDate = State(initialValue: clip.date)
    }

    private var isReview: Bool { onAdd != nil }

    /// The music track playing over this clip right now — the draft's in review,
    /// the store's live value once picked. Drives the Preview/Play music player.
    private var currentAudioTrack: AudioTrack? {
        isReview ? clip.audio : store.clips.first(where: { $0.id == clip.id })?.audio
    }

    /// The working copy with the picked date applied — what would be saved.
    private var editedClip: Clip {
        var updated = clip
        updated.date = editedDate.dayKey
        return updated
    }

    private var hasChanges: Bool {
        clip != original || editedDate.dayKey != original.date
    }

    var body: some View {
        editorBody
        .onAppear { setUp(); onLiveEdit?(editedClip) }
        .task { await loadThumbnails(url: sourceURL ?? store.fileURL(for: clip)) }
        .task {
            waveform = await loadAudioWaveform(
                url: sourceURL ?? store.fileURL(for: clip), buckets: 600)
        }
        .task { await loadVideoDisplaySize() }
        .onDisappear {
            // Auto-save so switching clips or closing the sheet keeps edits.
            // No-op if the clip was just deleted. Review drafts aren't in the
            // library, so there's nothing to save — but a draft that picked up
            // music and was never added leaves an orphan copy in Audio/, so drop
            // it (a no-op once a real clip references the file, i.e. it was added).
            if !isReview {
                saveEdits()
            } else if let track = clip.audio {
                store.pruneUnusedAudioFile(track)
            }
            tearDown()
        }
        .onChange(of: clip) { _, _ in onLiveEdit?(editedClip) }
        .onChange(of: editedDate) { _, _ in onLiveEdit?(editedClip) }
        .onChange(of: clip.inSeconds) { _, newValue in seek(to: newValue) }
        .onChange(of: clip.outSeconds) { _, newValue in seek(to: newValue) }
        .onChange(of: clip.volume) { _, newValue in
            player?.volume = Float(min(1, max(0, newValue)))
        }
        .onChange(of: currentAudioTrack?.fileName) { _, _ in loadMusicPlayer() }
        .sheet(isPresented: $showTransition) {
            TransitionEditorSheet(transition: $clip.transition, maxSeconds: clip.trimmedDuration)
        }
    }

    // MARK: - Layouts

    /// Two-column layout used in both modes: the media and trim controls take the
    /// whole left side so the video is as big as possible; tags/caption/
    /// transition/day and the add (review) or delete (library) action live in a
    /// resizable pane on the right.
    private var editorBody: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 14) {
                mediaAccessory
                mediaView
                // The video (above) takes the slack, so the trim row sits at the
                // bottom — level with the side pane's Revert/Delete and the rail
                // footer. No trailing Spacer (it would fight the video for space
                // and leave this row floating mid-column).
                trimControls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ResizablePaneDivider(width: $paneWidth)
            sidePane
                .frame(width: paneWidth)
        }
    }

    /// Right-hand metadata + actions pane.
    private var sidePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reviewInfo {
                ReviewItemHeader(info: reviewInfo)
                Divider()
            }
            TagRow(tags: $clip.tags)
            captionField
            TransitionRow(transition: clip.transition) { showTransition = true }
            volumeRow
            Divider()
            DayPickerField(selection: $editedDate)
            dateStampToggle
            // Library mode only: post this picked clip to another project.
            if !isReview {
                Divider()
                CopyClipToProjectMenu(clip: editedClip)
            }
            Spacer(minLength: 0)
            HStack {
                revertButton
                // Precise full-frame reset for the video crop (hand-dragging the
                // box never lands exactly on the edges); only when there's a crop.
                if clip.crop != nil {
                    Button("Reset Crop") { clip.crop = nil }
                        .help("Clear the crop and show the whole video frame")
                }
                Spacer()
                // Review adds a draft; library edits an existing clip.
                if isReview { addButton } else { deleteButton }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private var mediaView: some View {
        if let player {
            Group {
                if let videoDisplaySize {
                    // The yellow crop box is drawn right on the player, like the
                    // photo editor crops the still. The player is sized to the
                    // same fitted rect as the box, so the two stay aligned.
                    CropOverlay(contentSize: videoDisplaySize,
                                crop: cropBinding, aspect: nativeAspect) { fit in
                        PlayerView(player: player, controlsStyle: .none)
                            .frame(width: fit.width, height: fit.height)
                            .offset(x: fit.minX, y: fit.minY)
                    }
                } else {
                    PlayerView(player: player, controlsStyle: .none)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(minHeight: 260, maxHeight: .infinity)
            // The on-screen skip buttons were removed; surface the keys here,
            // on the natural hover target for jogging playback.
            .help("Drag the yellow box to crop · ← / → skip back / forward 5 seconds")
        }
    }

    private var cropBinding: Binding<CropRect> {
        Binding(
            get: { clip.crop ?? .full },
            set: { clip.crop = $0.isFull ? nil : $0 }
        )
    }

    /// The video's display width/height, once known — the ratio the crop is
    /// locked to, so it only zooms/pans and never reshapes the video.
    private var nativeAspect: Double? {
        guard let size = videoDisplaySize, size.width > 0, size.height > 0 else { return nil }
        return Double(size.width / size.height)
    }

    private var trimControls: some View {
        VStack(spacing: 14) {
            TrimSlider(
                duration: clip.durationSeconds,
                inSeconds: $clip.inSeconds,
                outSeconds: $clip.outSeconds,
                playheadSeconds: playheadSeconds,
                thumbnails: thumbnails,
                waveform: waveform,
                onScrub: { seconds in seek(to: seconds) }
            )
            .frame(height: waveform.isEmpty ? 56 : 92)

            // A music bar sits right under the clip's own audio waveform: lay a
            // song over the clip here, or (picked clips) jump to the Soundtrack
            // window to fine-tune it.
            ClipMusicLane(clip: clip, isReview: isReview, draftAudio: $clip.audio)

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
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .help("Play / pause the whole clip (Space)")
                Button {
                    isPreviewingTrim ? pausePlayback() : playTrimmedPreview()
                } label: {
                    // A hidden "Preview Trim" reserves the wider width (left
                    // aligned, so the icon stays put) — the row doesn't shift
                    // when the label flips to the shorter "Pause".
                    ZStack(alignment: .leading) {
                        Label("Preview Trim", systemImage: "play.rectangle.fill")
                            .hidden()
                        Label(isPreviewingTrim ? "Pause" : "Preview Trim",
                              systemImage: isPreviewingTrim ? "pause.fill" : "play.rectangle.fill")
                    }
                }
                .keyboardShortcut("p", modifiers: [])
                .help("Play just the trimmed in → out segment (P)")
                Text("Trim \(formatTime(clip.trimmedDuration)) of \(formatTime(clip.durationSeconds))")
                    .foregroundStyle(.secondary)
                    .help("Length of the trimmed segment, out of the clip's full length")
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
        }
    }

    private var captionField: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble")
                .foregroundStyle(.secondary)
            TextField("Caption (optional)", text: $clip.caption)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Audio level for this clip in the rendered video: 0% mutes, 100% is the
    /// original, up to 400% boosts (handy for a very quiet clip — though a clip
    /// that's already loud will clip before reaching the top). The speaker icon
    /// reflects the level and resets it to 100% when clicked.
    private var volumeRow: some View {
        HStack(spacing: 8) {
            Button {
                clip.volume = 1
                commitLiveEdit()
            } label: {
                Image(systemName: volumeSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help("Reset volume to 100%")
            Slider(value: $clip.volume, in: 0...4) { editing in
                // Commit on release so an already-open Preview Day window
                // rebuilds with the new level instead of replaying the old one.
                if !editing { commitLiveEdit() }
            }
            Text("\(Int((clip.volume * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .help("How loud this clip's audio plays in the rendered video (0–400%). A boost above 100% is applied to the exported file — the in-app preview can't play louder than 100%, so use Save… to hear it.")
    }

    /// Push the current edit straight to the store so an open Preview Day
    /// window (and the calendar) reflect it immediately. Editors otherwise only
    /// persist on disappear, which leaves an open preview playing the old value.
    /// Library mode only — review drafts aren't in the store yet.
    private func commitLiveEdit() {
        guard !isReview else { return }
        saveEdits()
    }

    private var volumeSymbol: String {
        switch clip.volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.67: return "speaker.wave.1.fill"
        case ..<1.34: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var dateStampToggle: some View {
        Toggle("Date stamp", isOn: $clip.showsDateOverlay)
            .toggleStyle(.checkbox)
            .help("Show this clip's date in the bottom-left corner of the month video. Turn off for 1SE imports (already stamped) or cover clips.")
    }

    private var revertButton: some View {
        Button {
            pausePlayback()
            // Reverting a review draft drops any music it picked up, so delete
            // that now-orphan copy before the wholesale reset loses the ref.
            if isReview, let track = clip.audio { store.pruneUnusedAudioFile(track) }
            clip = original
            editedDate = original.date
        } label: {
            Label("Revert", systemImage: "arrow.uturn.backward")
        }
        .disabled(!hasChanges)
        .help("Discard this clip's unsaved changes")
    }

    @ViewBuilder
    private var addButton: some View {
        if let onAdd {
            Button {
                pausePlayback()
                var added = clip
                added.date = editedDate.dayKey
                onAdd(added)
            } label: {
                Label("Add to Clips", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Add this trimmed segment to the day's clips (⌘↩)")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            pausePlayback()
            if let onDelete {
                onDelete()
            } else {
                store.delete(clip)
                dismiss()
            }
        } label: {
            Label("Delete Clip", systemImage: "trash")
        }
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
        if isPlaying { pausePlayback() }
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
        // AVPlayer's volume is capped at 1.0, so the scrub preview can reflect
        // muting/attenuation but not a >100% boost (that still applies in the
        // rendered video via the export's audio mix).
        newPlayer.volume = Float(min(1, max(0, clip.volume)))
        player = newPlayer
        seek(to: clip.inSeconds)
        loadMusicPlayer()

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            playheadSeconds = seconds
            guard isPlaying else { return }
            // Preview Trim stops at the out-point; the transport play runs to the
            // end of the clip.
            if stopAtOut {
                if seconds >= clip.outSeconds { pausePlayback() }
            } else if seconds >= clip.durationSeconds - 0.03 {
                pausePlayback()
            }
            // Keep the overlaid music aligned, and start/stop it as playback
            // enters/leaves the trimmed segment (it ends at the clip's out-point
            // even when the video plays on to its natural end).
            syncMusic(at: seconds)
        }

        // Space toggles play/pause, like the player's old built-in controls did —
        // but only when the user isn't typing in a text field (caption, tags…),
        // so it doesn't swallow spaces.
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, // Space
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !isEditingText() else { return event }
            togglePlay()
            return nil
        }
    }

    /// Whether a text field is currently being edited in the key window, so the
    /// Space shortcut should yield to it.
    private func isEditingText() -> Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private func tearDown() {
        pausePlayback()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
        musicPlayer?.stop()
        musicPlayer = nil
        if let spaceKeyMonitor {
            NSEvent.removeMonitor(spaceKeyMonitor)
            self.spaceKeyMonitor = nil
        }
    }

    private func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    /// True while a Preview Trim is playing (so its button shows "Stop").
    private var isPreviewingTrim: Bool { isPlaying && stopAtOut }

    /// Transport play/pause: plays the whole clip from the current position
    /// (restarting from the top if parked at the end), or pauses.
    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            pausePlayback()
        } else {
            if let now = currentPlayerSeconds, now >= clip.durationSeconds - 0.05 {
                seek(to: 0)
            }
            stopAtOut = false
            player.play()
            isPlaying = true
            syncMusic(at: currentPlayerSeconds ?? clip.inSeconds)
        }
    }

    private func playTrimmedPreview() {
        seek(to: clip.inSeconds)
        stopAtOut = true
        player?.play()
        isPlaying = true
        syncMusic(at: clip.inSeconds)
    }

    private func pausePlayback() {
        player?.pause()
        musicPlayer?.pause()
        isPlaying = false
        stopAtOut = false
    }

    /// (Re)load the music player from the current audio track, or clear it when
    /// there's none. Kept in step with the track via `currentAudioTrack`.
    private func loadMusicPlayer() {
        guard let track = currentAudioTrack else { musicPlayer = nil; return }
        let loaded = try? AVAudioPlayer(contentsOf: store.audioURL(for: track))
        // Like the video player, the preview tops out at 100%; a >100% boost
        // still applies in the rendered file.
        loaded?.volume = Float(min(1, max(0, track.volume)))
        loaded?.prepareToPlay()
        musicPlayer = loaded
    }

    /// Align the music to video time `v` and start/stop it so the song is heard
    /// only over the trimmed segment, beginning at the clip's in-point (matching
    /// how the export lays a this-clip track down). Called on play and each tick.
    private func syncMusic(at v: Double) {
        guard let musicPlayer, let track = currentAudioTrack else { return }
        let fileTime = track.offsetSeconds + (v - clip.inSeconds)
        guard isPlaying, v >= clip.inSeconds, v < clip.outSeconds,
              fileTime >= 0, fileTime < musicPlayer.duration else {
            musicPlayer.pause()
            return
        }
        // Only reseek on real drift so the 30 Hz observer doesn't stutter it.
        if abs(musicPlayer.currentTime - fileTime) > 0.15 {
            musicPlayer.currentTime = fileTime
        }
        if !musicPlayer.isPlaying { musicPlayer.play() }
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

    /// Loads the video's oriented display size (natural size with its
    /// preferred transform applied), so the crop box can fit and lock to the
    /// video's real on-screen shape.
    private func loadVideoDisplaySize() async {
        let url = sourceURL ?? store.fileURL(for: clip)
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferred = try? await track.load(.preferredTransform) else { return }
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        videoDisplaySize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
    }
}

/// Thumbnail filmstrip with draggable in/out handles, plus an optional audio
/// waveform lane underneath so speech and sound onsets are easy to trim to.
struct TrimSlider: View {
    let duration: Double
    @Binding var inSeconds: Double
    @Binding var outSeconds: Double
    var playheadSeconds: Double = 0
    let thumbnails: [NSImage]
    /// Normalized (0...1) peak amplitudes across the whole clip; empty hides the
    /// waveform lane (the asset has no audio, or it's still loading).
    var waveform: [Float] = []
    var onScrub: (Double) -> Void

    private let handleWidth: CGFloat = 12
    private let minGap = 0.1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let totalH = geo.size.height
            // The waveform takes a slim lane at the bottom; the filmstrip keeps
            // the rest. Both are full-width so the same x is the same time.
            let waveH: CGFloat = waveform.isEmpty ? 0 : min(34, totalH * 0.42)
            let stripH = totalH - waveH
            let inX = position(of: inSeconds, width: width)
            let outX = position(of: outSeconds, width: width)

            ZStack(alignment: .leading) {
                // Filmstrip on top, audio waveform lane below.
                VStack(spacing: 0) {
                    filmstrip(width: width, height: stripH)
                    if waveH > 0 {
                        WaveformView(samples: waveform)
                            .frame(width: width, height: waveH)
                            .background(Color.black.opacity(0.55))
                    }
                }
                .frame(width: width, height: totalH)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Dimmed (cut) regions — over filmstrip and waveform both
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, inX), height: totalH)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, width - outX), height: totalH)
                    .offset(x: outX)

                // Selection border
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(handleWidth * 2, outX - inX), height: totalH)
                    .offset(x: inX)

                // Playhead (current playback position)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: totalH)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(x: position(of: playheadSeconds, width: width) - 1)
                    .allowsHitTesting(false)

                // In handle
                handle(height: totalH)
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
                handle(height: totalH)
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

    private func filmstrip(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: max(1, width / CGFloat(max(1, thumbnails.count))),
                           height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height)
        .background(Color.black.opacity(0.4))
    }

    private func handle(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: height)
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

/// A mirrored bar waveform (peaks above and below a center line) for the trim
/// slider's audio lane. `samples` are normalized 0...1 amplitudes, left→right.
struct WaveformView: View {
    let samples: [Float]
    var color: Color = .white.opacity(0.55)

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0 else { return }
            let midY = size.height / 2
            let step = size.width / CGFloat(samples.count)
            let barWidth = max(0.6, step * 0.85)
            for (i, amp) in samples.enumerated() {
                let x = (CGFloat(i) + 0.5) * step
                let half = max(0.5, CGFloat(amp) * (midY - 1))
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: midY - half))
                bar.addLine(to: CGPoint(x: x, y: midY + half))
                context.stroke(bar, with: .color(color),
                               style: StrokeStyle(lineWidth: barWidth, lineCap: .round))
            }
        }
    }
}

/// Reads `url`'s audio track and returns `buckets` normalized peak amplitudes
/// (0...1) spanning the whole clip, for the trim slider's waveform lane.
/// Returns an empty array when the asset has no audio. Decodes to 16 kHz mono
/// PCM (ample for a visual) and runs off the main actor.
func loadAudioWaveform(url: URL, buckets: Int) async -> [Float] {
    let asset = AVURLAsset(url: url)
    guard buckets > 0,
          let track = try? await asset.loadTracks(withMediaType: .audio).first,
          let durationTime = try? await asset.load(.duration) else { return [] }
    let duration = durationTime.seconds
    guard duration.isFinite, duration > 0 else { return [] }
    guard let reader = try? AVAssetReader(asset: asset) else { return [] }

    let sampleRate = 16_000.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: sampleRate
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }

    let totalFrames = max(1, Int(duration * sampleRate))
    var peaks = [Float](repeating: 0, count: buckets)
    var frameIndex = 0

    while reader.status == .reading {
        guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
        if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(block)
            var dataPointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: nil,
                                           dataPointerOut: &dataPointer) == noErr,
               let dataPointer {
                let count = length / MemoryLayout<Int16>.size
                dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                    for i in 0..<count {
                        let amp = Float(abs(Int32(samples[i]))) / Float(Int16.max)
                        let bucket = min(buckets - 1, (frameIndex + i) * buckets / totalFrames)
                        if amp > peaks[bucket] { peaks[bucket] = amp }
                    }
                }
                frameIndex += count
            }
        }
        CMSampleBufferInvalidate(sampleBuffer)
        if Task.isCancelled { reader.cancelReading(); return [] }
    }

    guard reader.status != .failed else { return [] }
    return normalizedWaveform(peaks)
}

/// Scales peaks so the 95th-percentile level maps to 1.0 — that way a lone loud
/// transient (a clap, a bump) doesn't flatten quieter speech to nothing.
private func normalizedWaveform(_ peaks: [Float]) -> [Float] {
    let positive = peaks.filter { $0 > 0 }.sorted()
    guard let loudest = positive.last, loudest > 0 else { return peaks }
    let reference = positive[Int(Double(positive.count - 1) * 0.95)]
    let denom = max(reference, loudest * 0.15, 0.0001)
    return peaks.map { min(1, $0 / denom) }
}
