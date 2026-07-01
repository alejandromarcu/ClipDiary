import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Opens the Soundtrack window scrolled near a day — the day the main window is
/// currently showing (the calendar's month → its first day; the timeline's
/// topmost visible day) so the soundtrack lands on the same stretch of time.
struct SoundtrackRequest: Codable, Hashable {
    var anchorDate: Date
}

/// The scrolled-into-view window of the timeline, in timeline points: the
/// content x at the viewport's leading edge and the viewport's width. Fed by
/// `onScrollGeometryChange` so the month-name row can keep each month's label
/// pinned to what's actually on screen (a sticky-header effect).
private struct ScrollMetrics: Equatable { var left: CGFloat; var width: CGFloat }

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
    /// The day to land near (see `SoundtrackRequest`).
    let anchorDate: Date

    /// The month `anchorDate` falls in — what the Preview button renders and
    /// labels itself with (the soundtrack previews a whole month).
    private var anchorMonth: Date {
        Calendar.current.dateInterval(of: .month, for: anchorDate)?.start ?? anchorDate
    }

    /// Horizontal scale: points per second of timeline.
    @State private var pps: Double = 30
    @State private var selected: UUID?
    @State private var waveforms: [String: [Float]] = [:]
    @State private var durations: [String: Double] = [:]
    @State private var showImporter = false
    @State private var addAtSeconds: Double?
    @State private var drag: DragState?
    @State private var scrollLeft: CGFloat = 0
    @State private var viewportWidth: CGFloat = 2000
    @State private var scrollPosition = ScrollPosition()
    /// Guards the one-time scroll-to-anchor so re-layouts don't yank the user
    /// back to the anchor day after they've scrolled away.
    @State private var didInitialScroll = false

    private let monthRowH: CGFloat = 24   // month name above the day numbers
    private let labelRowH: CGFloat = 22   // day numbers above the clips
    /// y of the top hairline rule (kept just inside the canvas so it isn't clipped).
    private let topRuleY: CGFloat = 0.5
    private let stripHeight: CGFloat = 90
    private let laneHeight: CGFloat = 74
    private let rowGap: CGFloat = 12
    private let topPad: CGFloat = 12
    /// How close (points) a dragged edge must be to a day/clip line to snap.
    private let snapPoints: CGFloat = 8
    private static let audioTypes: [UTType] = [.mp3, .wav, .mpeg4Audio, .aiff, .audio]

    /// Full height of the scrolling timeline content (month row + label row +
    /// strip + lane).
    private var contentHeight: CGFloat { monthRowH + labelRowH + stripHeight + rowGap + laneHeight }

    /// The currently-scrolled-into-view x-range (timeline points), used to
    /// keep a month's label on screen as long as any of its days are visible.
    private var visibleLeft: CGFloat { scrollLeft }
    private var visibleRight: CGFloat { scrollLeft + viewportWidth }

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

    var body: some View {
        let layout = store.timelineLayout()
        let grid = store.timelineGrid()
        let blocks = audioBlocks(layout)
        let totalWidth = max(0, CGFloat(layout.total) * pps)

        VStack(spacing: 0) {
            header
            Divider()
            if layout.order.isEmpty {
                emptyState
            } else {
                timeline(layout: layout, grid: grid, blocks: blocks, totalWidth: totalWidth)
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

    private func timeline(layout: LibraryStore.TimelineLayout, grid: LibraryStore.TimelineGrid,
                          blocks: [Block], totalWidth: CGFloat) -> some View {
        ScrollView([.horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(width: totalWidth, height: monthRowH + labelRowH)
                clipStrip(layout, width: totalWidth)
                Color.clear.frame(height: rowGap)
                audioLane(layout: layout, blocks: blocks, width: totalWidth)
            }
            // Day separators + labels and dotted clip separators, drawn
            // across the whole content (above the clips, down to the
            // bottom of the audio). Non-interactive so gestures pass through.
            .overlay(alignment: .topLeading) {
                dayClipLines(grid, width: totalWidth,
                            visibleLeft: visibleLeft, visibleRight: visibleRight)
                    .allowsHitTesting(false)
            }
            .padding(.top, topPad)
            .padding(.trailing, 16)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
            ScrollMetrics(left: geo.contentOffset.x, width: geo.containerSize.width)
        } action: { _, m in
            scrollLeft = m.left
            viewportWidth = m.width
        }
        .onAppear {
            // Scroll to the anchor day. It's positioned by a raw content
            // offset (not a scrollTo-an-id, which would resolve the anchor's
            // *layout* frame — always the strip's origin, since the clips are
            // placed by `.offset`, so it would always jump to the start).
            guard let s = anchorStartSeconds(grid), !didInitialScroll else { return }
            didInitialScroll = true
            let targetX = xPos(s)
            DispatchQueue.main.async {
                scrollPosition.scrollTo(x: targetX)
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
            // Only the clips scrolled into view are built (+ a screen of margin),
            // so a project with thousands of clips doesn't materialize — and
            // decode thumbnails for — them all at once.
            ForEach(visibleClips(layout)) { clip in
                ClipStripCell(clip: clip, cellWidth: cellWidth(clip, layout), height: stripHeight)
                    .offset(x: xPos(layout.startByID[clip.id] ?? 0))
            }
        }
        .frame(width: width, height: stripHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The clips whose pixel span intersects the scrolled-into-view window (plus
    /// a screen of margin each side). Bounds the per-frame view + thumbnail work
    /// to what's near the viewport instead of the whole project.
    private func visibleClips(_ l: LibraryStore.TimelineLayout) -> [Clip] {
        let lo = scrollLeft - viewportWidth
        let hi = scrollLeft + 2 * viewportWidth
        return l.order.filter { clip in
            guard let s = l.startByID[clip.id], let e = l.endByID[clip.id] else { return false }
            return xPos(e) >= lo && xPos(s) <= hi
        }
    }

    /// Vertical day/clip separators with day numbers and a month-name row above
    /// them, plus horizontal rules under each label row, drawn over the whole
    /// timeline. Day lines are solid and start just above the day numbers
    /// (heavier where a day also starts a new month); clip lines are dotted
    /// and start at the clip tops. A month's label is clamped to
    /// `visibleLeft...visibleRight` (the scrolled-into-view window) — like a
    /// sticky header — so it stays on screen as long as any of its days are
    /// visible, instead of disappearing once the month's true midpoint
    /// scrolls off either edge.
    private func dayClipLines(_ grid: LibraryStore.TimelineGrid, width: CGFloat,
                              visibleLeft: CGFloat, visibleRight: CGFloat) -> some View {
        let months = grid.months
        let monthStarts = Set(months.map(\.start))
        let stripTop = monthRowH + labelRowH
        // Only draw separators/labels within the scrolled-into-view window (plus
        // a small pad): on a long timeline drawing every line + day number each
        // scroll frame is what makes the Canvas — and scrolling — lag.
        let lo = visibleLeft - 50
        let hi = visibleRight + 50
        return Canvas { ctx, size in
            // Hairline rules framing the two header rows: above the month name,
            // between the month name and the day numbers, and below the day
            // numbers (above the clips).
            for y in [topRuleY, monthRowH, stripTop] {
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: y))
                rule.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(rule, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 1))
            }

            for x in grid.clipLines {
                let px = xPos(x)
                guard px >= lo, px <= hi else { continue }
                var p = Path()
                p.move(to: CGPoint(x: px, y: stripTop))
                p.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(p, with: .color(.secondary.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            for d in grid.days {
                let px = xPos(d.start)
                let ex = xPos(d.end)
                guard ex >= lo, px <= hi else { continue }   // span off-screen
                let isMonthStart = monthStarts.contains(d.start)
                // A regular day line tops out at the rule above the day numbers;
                // only a month boundary runs full height (up through the month
                // row) so the month divisions read clearly.
                let top: CGFloat = isMonthStart ? topRuleY : monthRowH
                if px >= lo, px <= hi {
                    var p = Path()
                    p.move(to: CGPoint(x: px, y: top))
                    p.addLine(to: CGPoint(x: px, y: size.height))
                    ctx.stroke(p, with: .color(.secondary.opacity(isMonthStart ? 0.8 : 0.55)),
                               style: StrokeStyle(lineWidth: isMonthStart ? 1.5 : 1))
                }
                if ex - px >= 18 {
                    let cx = (px + ex) / 2
                    if cx >= lo, cx <= hi {
                        ctx.draw(Text(d.label).font(.callout).foregroundStyle(.secondary),
                                 at: CGPoint(x: cx, y: monthRowH + labelRowH / 2))
                    }
                }
            }
            for m in months {
                let mLeft = xPos(m.start), mRight = xPos(m.end)
                let segLeft = max(mLeft, visibleLeft)
                let segRight = min(mRight, visibleRight)
                guard segRight > segLeft else { continue }
                // Rough width estimate (avoids a Canvas text-measure round trip) —
                // generous on purpose so the clamp keeps clear of the boundary.
                let textWidth = CGFloat(m.label.count) * 9 + 8
                let minCx = mLeft + textWidth / 2 + 4
                let maxCx = mRight - textWidth / 2 - 4
                let centered = (segLeft + segRight) / 2
                let cx = minCx <= maxCx ? min(max(centered, minCx), maxCx) : (mLeft + mRight) / 2
                ctx.draw(Text(m.label).font(.title3.weight(.semibold)).foregroundStyle(.primary),
                         at: CGPoint(x: cx, y: monthRowH / 2))
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

    /// The timeline seconds to scroll to for `anchorDate`: the start of that
    /// day's clips if that day has any, otherwise the nearest day on/after it
    /// (falling back to the last day) so the window still lands in the right
    /// stretch of time when the exact day is empty. `nil` only when there are no
    /// days at all (the empty state, where no timeline is drawn).
    private func anchorStartSeconds(_ grid: LibraryStore.TimelineGrid) -> Double? {
        let dayInterval = anchorDate.dayKey.timeIntervalSinceReferenceDate
        if let exact = grid.days.first(where: { $0.key == "\(dayInterval)" }) { return exact.start }
        let dated = grid.days.compactMap { span in Double(span.key).map { ($0, span.start) } }
        if let after = dated.filter({ $0.0 >= dayInterval }).min(by: { $0.0 < $1.0 }) { return after.1 }
        return dated.max(by: { $0.0 < $1.0 })?.1
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

    /// Current display geometry for a block, applying any in-flight drag.
    private func geometry(_ base: Block, layout l: LibraryStore.TimelineLayout,
                          blocks: [Block]) -> (start: Double, end: Double) {
        guard let d = drag, d.id == base.track.id else { return (base.start, base.end) }
        let dsec = Double(d.dx) / pps
        let (lo, hi) = neighborBounds(base, blocks: blocks, total: l.total)
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
    private func neighborBounds(_ base: Block, blocks: [Block], total: Double) -> (lo: Double, hi: Double) {
        var lo = 0.0
        var hi = total
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

}

// MARK: - Clip strip cell

private struct ClipStripCell: View {
    @EnvironmentObject var store: LibraryStore
    let clip: Clip
    /// This cell's full width (its rendered duration in pixels) and height.
    let cellWidth: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    /// Reloads the thumbnail only when the clip's content changes or the cell
    /// crosses `thumbMinWidth`, so continuous zooming doesn't re-decode.
    private var thumbTaskID: String {
        "\(store.thumbnailKey(for: clip))|\(cellWidth >= ClipStripCell.thumbMinWidth)"
    }

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
            // Photo/video (or card) icon + duration, matching the calendar's
            // timeline thumbnails — only as much as fits the thumbnail width.
            .overlay(alignment: .bottomLeading) { kindBadge }
            if thumbWidth < cellWidth {
                // The clip keeps showing this same frame for its remaining
                // duration — a neutral fill instead of stretching the image,
                // so the boundary with the next clip stays unambiguous.
                Color(nsColor: .windowBackgroundColor)
                    .frame(width: cellWidth - thumbWidth, height: height)
            }
        }
        .frame(width: cellWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.15), lineWidth: 0.5))
        .help(clip.date.formatted(date: .abbreviated, time: .omitted))
        .task(id: thumbTaskID) {
            // Don't decode a thumbnail for a sliver too thin to show one (zoomed
            // out): the neutral fill stands in until the user zooms in. The id
            // flips only when crossing the width threshold, so zooming within a
            // side doesn't reload.
            guard cellWidth >= ClipStripCell.thumbMinWidth else { image = nil; return }
            image = await store.thumbnail(for: clip)
        }
    }

    /// Below this cell width the thumbnail isn't worth decoding (and barely
    /// visible), so it's skipped.
    fileprivate static let thumbMinWidth: CGFloat = 8

    @ViewBuilder
    private var kindBadge: some View {
        if thumbWidth >= 22 {
            HStack(spacing: 2) {
                Image(systemName: clip.isCard ? "rectangle.on.rectangle.angled"
                                              : (clip.kind == .photo ? "photo" : "video"))
                if thumbWidth >= 52 {
                    Text(formatTime(clip.trimmedDuration))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(4)
        }
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
