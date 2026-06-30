import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Opens the Soundtrack window scrolled to a month.
struct SoundtrackRequest: Codable, Hashable {
    var anchorMonth: Date
}

/// The background-audio timeline: the project's clips laid end-to-end on a time
/// axis with a draggable audio lane beneath. Each song is a block — click an
/// empty part of the lane to add one, drag the body to reposition it (offset),
/// drag the right edge to set where it stops, the left edge to set where it
/// starts. Blocks never overlap. Geometry comes from `store.timelineLayout()`,
/// the same positions the exporter renders, so the lane is WYSIWYG.
struct SoundtrackView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let anchorMonth: Date

    /// Horizontal scale: points per second of timeline.
    @State private var pps: Double = 30
    @State private var selected: UUID?
    @State private var waveforms: [String: [Float]] = [:]
    @State private var durations: [String: Double] = [:]
    @State private var showImporter = false
    @State private var addAtSeconds: Double?
    @State private var drag: DragState?

    private let labelRowH: CGFloat = 18   // day labels above the clips
    private let stripHeight: CGFloat = 60
    private let laneHeight: CGFloat = 74
    private let rowGap: CGFloat = 12
    private let topPad: CGFloat = 12
    /// How close (points) a dragged edge must be to a day/clip line to snap.
    private let snapPoints: CGFloat = 8
    private static let audioTypes: [UTType] = [.mp3, .wav, .mpeg4Audio, .aiff, .audio]

    /// Full height of the scrolling timeline content (label row + strip + lane).
    private var contentHeight: CGFloat { labelRowH + stripHeight + rowGap + laneHeight }

    private enum DragMode { case body, leftEdge, rightEdge }
    private struct DragState { let id: UUID; let mode: DragMode; var dx: CGFloat }

    /// A placed audio block on the timeline (seconds), derived from a clip's
    /// `audio` and the shared layout.
    private struct Block: Identifiable {
        let track: AudioTrack
        let startClipID: UUID
        let start: Double          // audible start, seconds
        let end: Double            // audible end, seconds
        var id: UUID { track.id }
    }

    /// One calendar day's run of clips on the timeline (seconds), with the label
    /// to write above it.
    private struct DaySpan: Identifiable {
        let key: String; let label: String; let start: Double; let end: Double
        var id: String { key }
    }

    var body: some View {
        let layout = store.timelineLayout()
        let blocks = audioBlocks(layout)
        let totalWidth = max(0, CGFloat(layout.total) * pps)

        VStack(spacing: 0) {
            header
            Divider()
            if layout.order.isEmpty {
                emptyState
            } else {
                timeline(layout: layout, blocks: blocks, totalWidth: totalWidth)
                    .frame(height: contentHeight + topPad + 24)
                Divider()
                inspector(blocks: blocks)
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 640, idealWidth: 1000, maxWidth: .infinity,
               minHeight: 300, idealHeight: 360, maxHeight: .infinity, alignment: .top)
        .background {
            Button("Close") { /* window close via Esc */ }
                .keyboardShortcut(.cancelAction).hidden()
        }
        .navigationTitle("Soundtrack")
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.audioTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                addAudio(from: url)
            }
        }
        .task(id: blocks.map(\.track.fileName).sorted().joined(separator: "|")) {
            await loadMissingWaveforms(blocks)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            Text("Drag a song to move it, its edges to set start and end. Click the lane to add one.")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Button { previewMonth() } label: {
                Label("Preview \(anchorMonth.formatted(.dateTime.month(.abbreviated)))", systemImage: "play.fill")
            }
            .help("Preview this month with its soundtrack")
            Divider().frame(height: 16)
            Button { pps = max(6, pps / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { pps = min(240, pps * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.system(size: 38)).foregroundStyle(.secondary)
            Text("No clips yet — add some clips first, then lay music over them.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Timeline

    private func timeline(layout: LibraryStore.TimelineLayout,
                          blocks: [Block], totalWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Fixed, non-scrolling row labels so the two lanes are unambiguous.
            VStack(alignment: .trailing, spacing: rowGap) {
                Text("Clips").frame(height: stripHeight)
                Text("Audio").frame(height: laneHeight)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, topPad + labelRowH)
            .frame(width: 42)

            ScrollViewReader { proxy in
                ScrollView([.horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(width: totalWidth, height: labelRowH)
                        clipStrip(layout, width: totalWidth)
                        Color.clear.frame(height: rowGap)
                        audioLane(layout: layout, blocks: blocks, width: totalWidth)
                    }
                    // Day separators + labels and dotted clip separators, drawn
                    // across the whole content (above the clips, down to the
                    // bottom of the audio). Non-interactive so gestures pass through.
                    .overlay(alignment: .topLeading) {
                        dayClipLines(layout, width: totalWidth).allowsHitTesting(false)
                    }
                    .padding(.top, topPad)
                    .padding(.trailing, 16)
                }
                .onAppear {
                    let key = monthKey(anchorMonth)
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo("month-\(key)", anchor: .leading) }
                    }
                }
            }
        }
        .padding(.leading, 12)
    }

    private func clipStrip(_ layout: LibraryStore.TimelineLayout, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Each cell is positioned absolutely at the SAME xPos the day/clip
            // lines use, so a cell's left edge and its line are the identical
            // computation — pixel-locked at every zoom. (An HStack lets SwiftUI
            // place cells by its own cumulative rounding, which can land a line a
            // pixel into a clip — very visible on narrow, low-zoom clips.)
            ForEach(layout.order) { clip in
                ClipStripCell(clip: clip, cellWidth: cellWidth(clip, layout), height: stripHeight)
                    .offset(x: xPos(layout.startByID[clip.id] ?? 0))
            }
            // Invisible anchors at month starts, so "scroll to month" still works.
            ForEach(monthMarkers(layout)) { m in
                Color.clear.frame(width: 1, height: 1)
                    .id("month-\(m.key)")
                    .offset(x: xPos(m.startSec))
            }
        }
        .frame(width: width, height: stripHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Vertical day/clip separators with day labels, drawn over the whole
    /// timeline. Day lines are solid and start just above the clips with the day
    /// written between them; clip lines are dotted and start at the clip tops.
    private func dayClipLines(_ l: LibraryStore.TimelineLayout, width: CGFloat) -> some View {
        let info = dayInfo(l)
        let stripTop = labelRowH
        return Canvas { ctx, size in
            for x in info.clipLines {
                let px = xPos(x)
                var p = Path()
                p.move(to: CGPoint(x: px, y: stripTop))
                p.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(p, with: .color(.secondary.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            for d in info.days {
                let px = xPos(d.start)
                var p = Path()
                p.move(to: CGPoint(x: px, y: 2))
                p.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(p, with: .color(.secondary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1))
                let spanW = xPos(d.end) - xPos(d.start)
                if spanW >= 16 {
                    let cx = (xPos(d.start) + xPos(d.end)) / 2
                    ctx.draw(Text(d.label).font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: cx, y: labelRowH / 2))
                }
            }
        }
        .frame(width: width, height: contentHeight, alignment: .topLeading)
    }

    private func audioLane(layout: LibraryStore.TimelineLayout,
                           blocks: [Block], width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: width, height: laneHeight)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
                .gesture(SpatialTapGesture().onEnded { value in
                    beginAdd(atSeconds: Double(value.location.x) / pps, layout: layout)
                })

            ForEach(blocks) { base in
                let g = geometry(base, layout: layout, blocks: blocks)
                let x0 = xPos(g.start)
                let w = max(8, xPos(g.end) - xPos(g.start))
                AudioBlockView(
                    label: base.track.label,
                    waveform: waveformSlice(base, geometry: g),
                    selected: selected == base.track.id,
                    onSelect: { selected = base.track.id },
                    onBody: { tx, ended in handleDrag(base, .body, tx, ended, layout: layout, blocks: blocks) },
                    onLeft: { tx, ended in handleDrag(base, .leftEdge, tx, ended, layout: layout, blocks: blocks) },
                    onRight: { tx, ended in handleDrag(base, .rightEdge, tx, ended, layout: layout, blocks: blocks) }
                )
                .frame(width: w, height: laneHeight)
                .position(x: x0 + w / 2, y: laneHeight / 2)
            }
        }
        .frame(width: width, height: laneHeight, alignment: .topLeading)
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspector(blocks: [Block]) -> some View {
        if let b = blocks.first(where: { $0.track.id == selected }) {
            HStack(spacing: 14) {
                Label(b.track.label, systemImage: "music.note")
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)

                if let day = store.clips.first(where: { $0.id == b.startClipID })?.date {
                    Text("Starts \(day.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("at").foregroundStyle(.secondary)
                    TextField("", value: positionBinding(b), format: .number.precision(.fractionLength(1)))
                        .labelsHidden().multilineTextAlignment(.trailing)
                        .monospacedDigit().frame(width: 58)
                    Text("s").foregroundStyle(.secondary)
                    Stepper("", value: positionBinding(b), in: 0...100_000, step: 0.1).labelsHidden()
                }
                .help("Where the song starts on the timeline, in seconds from the start of the video.")

                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                    Slider(value: volumeBinding(b), in: 0...4).frame(width: 120)
                    Text("\(Int((b.track.volume * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }

                Spacer()
                Button(role: .destructive) {
                    store.setAudioTrack(nil, onClip: b.startClipID)
                    selected = nil
                } label: { Label("Remove", systemImage: "trash") }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        } else {
            HStack {
                Text("Select a song to edit it, or click an empty part of the lane to add one.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    /// The block's absolute start on the timeline (seconds). Editing it moves
    /// the block — recomputing its start clip + offset and shifting its end to
    /// preserve length.
    private func positionBinding(_ b: Block) -> Binding<Double> {
        Binding(get: { b.start }, set: { newPos in
            let l = store.timelineLayout()
            let len = b.end - b.start
            let pos = max(0, newPos)
            let (clipID, off) = clipAndOffset(atSeconds: pos, layout: l)
            let (eClip, eWithin) = endAnchor(atSeconds: pos + len, layout: l)
            store.moveAudioTrack(b.track.id, toStartClip: clipID, offset: off,
                                 endClipID: eClip, endWithin: eWithin)
        })
    }
    private func volumeBinding(_ b: Block) -> Binding<Double> {
        Binding(get: { b.track.volume },
                set: { v in updateTrack(b) { $0.volume = v } })
    }
    private func updateTrack(_ b: Block, _ mutate: (inout AudioTrack) -> Void) {
        var t = b.track; mutate(&t)
        store.setAudioTrack(t, onClip: b.startClipID)
    }

    // MARK: - Geometry

    /// A timeline second's pixel x, rounded to the device grid. The single
    /// mapping used by the strip cells, the day/clip lines, and the audio blocks
    /// so they all land on the same integer positions (no drift).
    private func xPos(_ sec: Double) -> CGFloat { (CGFloat(sec) * pps).rounded() }

    /// A clip's cell width as the difference of its rounded cumulative edges, so
    /// cell boundaries telescope to exactly the line positions — no accumulated
    /// rounding. Tiny clips can be 0px wide (zoom in to see them).
    private func cellWidth(_ clip: Clip, _ l: LibraryStore.TimelineLayout) -> CGFloat {
        max(0, xPos(l.endByID[clip.id] ?? 0) - xPos(l.startByID[clip.id] ?? 0))
    }

    /// Build the placed blocks from clips that own audio.
    private func audioBlocks(_ l: LibraryStore.TimelineLayout) -> [Block] {
        l.order.compactMap { clip in
            guard let track = clip.audio, let s = l.startByID[clip.id] else { return nil }
            let start = s + max(0, track.offsetSeconds)
            let spanEnd: Double
            if let e = track.endClipID, let es = l.startByID[e], let ee = l.endByID[e] {
                spanEnd = track.endWithinSeconds.map { es + $0 } ?? ee
            } else {
                spanEnd = l.total
            }
            let fileCap = durations[track.fileName].map { start + ($0 - max(0, -track.offsetSeconds)) } ?? spanEnd
            let end = min(spanEnd, fileCap, l.total)
            guard end > start else { return nil }
            return Block(track: track, startClipID: clip.id, start: start, end: end)
        }
    }

    /// Groups consecutive clips by calendar day (for the solid day separators +
    /// labels), and collects the start seconds of clips that fall *within* a day
    /// (the dotted clip separators). The first clip of each day is a day line,
    /// not a dotted one.
    private func dayInfo(_ l: LibraryStore.TimelineLayout) -> (days: [DaySpan], clipLines: [Double]) {
        var days: [DaySpan] = []
        var clipLines: [Double] = []
        let cal = Calendar.current
        var prevMonth: Int? = nil
        var idx = 0
        while idx < l.order.count {
            let clip = l.order[idx]
            let day = clip.date.dayKey
            let start = l.startByID[clip.id] ?? 0
            var end = l.endByID[clip.id] ?? start
            var j = idx + 1
            while j < l.order.count, l.order[j].date.dayKey == day {
                if let s = l.startByID[l.order[j].id] { clipLines.append(s) }
                end = l.endByID[l.order[j].id] ?? end
                j += 1
            }
            let month = cal.component(.month, from: clip.date)
            // Show the month on the first day of a new month for context, else
            // just the day number (compact for ~1s-a-day clips).
            let label = month != prevMonth
                ? clip.date.formatted(.dateTime.month(.abbreviated).day())
                : "\(cal.component(.day, from: clip.date))"
            prevMonth = month
            days.append(DaySpan(key: "\(day.timeIntervalSinceReferenceDate)",
                                label: label, start: start, end: end))
            idx = j
        }
        return (days, clipLines)
    }

    /// Current display geometry for a block, applying any in-flight drag.
    private func geometry(_ base: Block, layout l: LibraryStore.TimelineLayout,
                          blocks: [Block]) -> (start: Double, end: Double) {
        guard let d = drag, d.id == base.track.id else { return (base.start, base.end) }
        let dsec = Double(d.dx) / pps
        let (lo, hi) = neighborBounds(base, blocks: blocks)
        let lines = boundaries(l)
        let snapSec = Double(snapPoints) / pps
        switch d.mode {
        case .body:
            let len = base.end - base.start
            var ns = max(lo, min(max(0, base.start + dsec), hi - len))
            // Snap whichever edge (start or end) is nearest a day/clip line.
            let s = snap(ns, to: lines, within: snapSec)
            let e = snap(ns + len, to: lines, within: snapSec)
            if let s, let e { ns = abs(s - ns) <= abs(e - (ns + len)) ? s : e - len }
            else if let s { ns = s }
            else if let e { ns = e - len }
            ns = max(lo, min(ns, hi - len))
            return (ns, ns + len)
        case .leftEdge:
            var ns = max(max(0, lo), min(base.start + dsec, base.end - 0.2))
            if let s = snap(ns, to: lines, within: snapSec) {
                ns = max(max(0, lo), min(s, base.end - 0.2))
            }
            return (ns, base.end)
        case .rightEdge:
            let cap = min(hi, min(base.start + fileLength(base), l.total))
            var ne = max(base.start + 0.2, min(base.end + dsec, cap))
            if let e = snap(ne, to: lines, within: snapSec) {
                ne = max(base.start + 0.2, min(e, cap))
            }
            return (base.start, ne)
        }
    }

    /// All snap targets: every clip's start plus the timeline end (day lines are
    /// a subset — each day begins at a clip start).
    private func boundaries(_ l: LibraryStore.TimelineLayout) -> [Double] {
        l.order.compactMap { l.startByID[$0.id] } + [l.total]
    }

    /// The nearest line to `v` if within `within` seconds, else nil.
    private func snap(_ v: Double, to lines: [Double], within: Double) -> Double? {
        guard let nearest = lines.min(by: { abs($0 - v) < abs($1 - v) }),
              abs(nearest - v) <= within else { return nil }
        return nearest
    }

    /// The seconds available on each side of `base` before it would hit a
    /// neighbouring block (or the timeline ends) — used to forbid overlap.
    private func neighborBounds(_ base: Block, blocks: [Block]) -> (lo: Double, hi: Double) {
        var lo = 0.0
        var hi = store.timelineLayout().total
        for o in blocks where o.track.id != base.track.id {
            if o.end <= base.start { lo = max(lo, o.end) }
            if o.start >= base.end { hi = min(hi, o.start) }
        }
        return (lo, hi)
    }

    private func fileLength(_ b: Block) -> Double {
        let full = durations[b.track.fileName] ?? (b.end - b.start)
        return max(0.2, full - max(0, -b.track.offsetSeconds))
    }

    // MARK: - Drag handling

    private func handleDrag(_ base: Block, _ mode: DragMode, _ tx: CGFloat, _ ended: Bool,
                            layout l: LibraryStore.TimelineLayout, blocks: [Block]) {
        if !ended {
            drag = DragState(id: base.track.id, mode: mode, dx: tx)
            return
        }
        let g = geometry(base, layout: l, blocks: blocks)
        drag = nil
        // Start moves for body/left drags; the right-edge drag keeps it.
        let sClip: UUID
        let off: Double
        if mode == .rightEdge {
            sClip = base.startClipID
            off = base.track.offsetSeconds
        } else {
            (sClip, off) = clipAndOffset(atSeconds: g.start, layout: l)
        }
        let (eClip, eWithin) = endAnchor(atSeconds: g.end, layout: l)
        store.moveAudioTrack(base.track.id, toStartClip: sClip, offset: off,
                             endClipID: eClip, endWithin: eWithin)
    }

    /// The clip whose segment contains `sec`, and the offset into it.
    private func clipAndOffset(atSeconds sec: Double, layout l: LibraryStore.TimelineLayout) -> (UUID, Double) {
        for c in l.order {
            if let s = l.startByID[c.id], let e = l.endByID[c.id], sec >= s, sec < e {
                return (c.id, sec - s)
            }
        }
        if let last = l.order.last, let s = l.startByID[last.id] {
            return (last.id, max(0, sec - s))
        }
        return (l.order.first?.id ?? UUID(), 0)
    }

    /// Anchors an audible end at `end` seconds to (the clip it falls in, how far
    /// into that clip it stops) — so a song can end mid-clip and a drag keeps its
    /// exact length instead of snapping to a clip boundary.
    private func endAnchor(atSeconds end: Double, layout l: LibraryStore.TimelineLayout) -> (UUID?, Double?) {
        let probe = max(0, end - 0.001)   // a boundary end belongs to the clip before it
        for c in l.order {
            if let s = l.startByID[c.id], let e = l.endByID[c.id], probe >= s, probe < e {
                return (c.id, max(0, min(end - s, e - s)))
            }
        }
        if let last = l.order.last, let s = l.startByID[last.id], let e = l.endByID[last.id] {
            return (last.id, max(0, min(end - s, e - s)))
        }
        return (nil, nil)
    }

    // MARK: - Preview

    /// Opens the month preview, first dismissing any existing one so it always
    /// rebuilds from the current arrangement (and restarts from the start)
    /// instead of refocusing a stale window.
    private func previewMonth() {
        let req = PreviewRequest(range: .month(anchorMonth))
        dismissWindow(value: req)
        DispatchQueue.main.async { openWindow(value: req) }
    }

    // MARK: - Add

    private func beginAdd(atSeconds sec: Double, layout l: LibraryStore.TimelineLayout) {
        addAtSeconds = sec
        showImporter = true
    }

    private func addAudio(from url: URL) {
        guard let sec = addAtSeconds else { return }
        addAtSeconds = nil
        let l = store.timelineLayout()
        let (clipID, off) = clipAndOffset(atSeconds: sec, layout: l)
        // Don't clobber a clip that already starts a song; the tap fell in a gap,
        // so the underlying clip should be free.
        guard store.clips.first(where: { $0.id == clipID })?.audio == nil else { return }
        guard let name = store.copyAudioFile(from: url) else { return }
        let track = AudioTrack(fileName: name, displayName: url.lastPathComponent,
                               offsetSeconds: max(0, off), endClipID: clipID)
        store.setAudioTrack(track, onClip: clipID)
        selected = track.id
    }

    // MARK: - Waveforms

    private func waveformSlice(_ b: Block, geometry g: (start: Double, end: Double)) -> [Float] {
        guard let full = waveforms[b.track.fileName], !full.isEmpty,
              let dur = durations[b.track.fileName], dur > 0 else { return [] }
        let inPoint = max(0, -b.track.offsetSeconds)
        let to = inPoint + (g.end - g.start)
        let n = full.count
        let i0 = max(0, min(n - 1, Int(inPoint / dur * Double(n))))
        let i1 = max(i0 + 1, min(n, Int(to / dur * Double(n))))
        return Array(full[i0..<i1])
    }

    private func loadMissingWaveforms(_ blocks: [Block]) async {
        for b in blocks where waveforms[b.track.fileName] == nil {
            let url = store.audioURL(for: b.track)
            let wf = await loadAudioWaveform(url: url, buckets: 1200)
            let dur = await loadAudioDuration(url)
            waveforms[b.track.fileName] = wf
            durations[b.track.fileName] = dur
        }
    }

    // MARK: - Month markers

    private struct MonthMarker: Identifiable {
        let key: String
        let label: String
        let startSec: Double
        var id: String { key }
    }

    private func monthKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    private func monthMarkers(_ l: LibraryStore.TimelineLayout) -> [MonthMarker] {
        var result: [MonthMarker] = []
        var seen = Set<String>()
        for c in l.order {
            let key = monthKey(c.date)
            if seen.insert(key).inserted {
                result.append(MonthMarker(
                    key: key,
                    label: c.date.formatted(.dateTime.month(.abbreviated).year()),
                    startSec: l.startByID[c.id] ?? 0))
            }
        }
        return result
    }
}

// MARK: - Clip strip cell

private struct ClipStripCell: View {
    @EnvironmentObject var store: LibraryStore
    let clip: Clip
    /// This cell's full width (its rendered duration in pixels) and height.
    let cellWidth: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    /// The thumbnail's own box: capped to a sensible width so a long-duration
    /// photo/card (held for several seconds) doesn't stretch one static frame
    /// across the whole cell — at high zoom that smears unrelated parts of the
    /// photo (background, edges) into what reads as separate content, and the
    /// visible slice changes with zoom. A short clip's cell still just shrinks
    /// the box to fit.
    private var thumbWidth: CGFloat { min(cellWidth, height * 1.4) }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.black.opacity(0.12)
                }
            }
            .frame(width: thumbWidth, height: height)
            .clipped()
            if thumbWidth < cellWidth {
                // The clip keeps showing this same frame for its remaining
                // duration — a neutral fill instead of stretching the image,
                // so the boundary with the next clip stays unambiguous.
                Color(nsColor: .windowBackgroundColor)
                    .frame(width: cellWidth - thumbWidth, height: height)
            }
        }
        .frame(width: cellWidth, height: height, alignment: .leading)
        .overlay(Rectangle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
        .help(clip.date.formatted(date: .abbreviated, time: .omitted))
        .task(id: store.thumbnailKey(for: clip)) { image = await store.thumbnail(for: clip) }
    }
}

// MARK: - Audio block

private struct AudioBlockView: View {
    let label: String
    let waveform: [Float]
    let selected: Bool
    let onSelect: () -> Void
    let onBody: (CGFloat, Bool) -> Void
    let onLeft: (CGFloat, Bool) -> Void
    let onRight: (CGFloat, Bool) -> Void

    private let accent = Color.accentColor

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.opacity(selected ? 0.22 : 0.13))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(accent.opacity(selected ? 0.9 : 0.4), lineWidth: selected ? 2 : 1))

            WaveformView(samples: waveform, color: accent.opacity(0.7))
                .padding(.top, 19).padding(.bottom, 6).padding(.horizontal, 9)
                .allowsHitTesting(false)

            HStack(spacing: 4) {
                Image(systemName: "music.note")
                Text(label).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption2.weight(.medium)).foregroundStyle(accent)
            .padding(.horizontal, 9).padding(.top, 4)
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                grip.highPriorityGesture(edgeDrag(onLeft))
                Spacer(minLength: 0)
                grip.highPriorityGesture(edgeDrag(onRight))
            }
        }
        // Clip the waveform + label to the block so they never spill over a
        // neighbour, and measure drags in global space so moving the view
        // during the drag doesn't feed back into the translation (jitter).
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { onBody($0.translation.width, false) }
            .onEnded { onBody($0.translation.width, true) })
    }

    private var grip: some View {
        Rectangle()
            .fill(accent.opacity(0.55))
            .frame(width: 7)
            .overlay(Rectangle().fill(.white.opacity(0.5)).frame(width: 1))
            .contentShape(Rectangle())
    }

    private func edgeDrag(_ cb: @escaping (CGFloat, Bool) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { cb($0.translation.width, false) }
            .onEnded { cb($0.translation.width, true) }
    }
}

/// Loads an audio file's duration in seconds (0 on failure).
private func loadAudioDuration(_ url: URL) async -> Double {
    let asset = AVURLAsset(url: url)
    guard let d = try? await asset.load(.duration) else { return 0 }
    let s = d.seconds
    return s.isFinite ? s : 0
}
