import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Opens the Soundtrack window scrolled near a day — the day the main window is
/// currently showing (the calendar's month → its first day; the timeline's
/// topmost visible day) so the soundtrack lands on the same stretch of time.
struct SoundtrackRequest: Codable, Hashable {
    var anchorDate: Date
    /// A track to pre-select and scroll to (the day window's "Add Music" / "Open
    /// in Soundtrack" hands off the clip's track here). Nil → just anchor to the
    /// day.
    var selectTrackID: UUID? = nil
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
    /// A track to pre-select and scroll to on open (see `SoundtrackRequest`).
    var selectTrackID: UUID? = nil

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
                bottomSection(blocks: blocks)
            }
        }
        .onChange(of: selected) { _, id in revealTrack(id) }
        .frame(minWidth: 720, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 460, idealHeight: 620, maxHeight: .infinity, alignment: .top)
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
            if let selectTrackID { selected = selectTrackID }
            // Scroll to the selected track's clip (if any) or the anchor day. It's
            // positioned by a raw content offset (not a scrollTo-an-id, which
            // would resolve the anchor's *layout* frame — always the strip's
            // origin, since the clips are placed by `.offset`, so it would always
            // jump to the start).
            guard let s = selectedTrackStartSeconds() ?? anchorStartSeconds(grid),
                  !didInitialScroll else { return }
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

    // MARK: - Tracks list + inspector

    /// The bottom area: a table of every track (in the order they appear) on the
    /// left, and an editor for the selected track on the right. Selecting a row
    /// highlights that block in the timeline above and scrolls it into view.
    private func bottomSection(blocks: [Block]) -> some View {
        HStack(spacing: 0) {
            tracksTable(blocks)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            selectedInspector(blocks)
        }
        .frame(maxHeight: .infinity)
    }

    /// The track table: one row per placed track, already in appearance order
    /// (`audioBlocks` walks the timeline). Row selection is the same `selected`
    /// the timeline highlights, so clicking a row and clicking a block agree.
    /// "Used" is how much of the track plays here (its span on the timeline),
    /// "Total" the full length of the audio file.
    private func tracksTable(_ blocks: [Block]) -> some View {
        Table(blocks, selection: $selected) {
            TableColumn("Track") { b in
                Label(b.track.label, systemImage: "music.note")
                    .lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Day") { b in
                Text(startDay(b).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 96, ideal: 116)
            TableColumn("Used") { b in
                Text(formatDurationShort(b.end - b.start))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 64)
            TableColumn("Total") { b in
                Text(durations[b.track.fileName].map(formatDurationShort) ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 64)
        }
        .overlay {
            if blocks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                    Text("No tracks yet — click the lane above to add one.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func selectedInspector(_ blocks: [Block]) -> some View {
        if let b = blocks.first(where: { $0.track.id == selected }) {
            TrackInspector(track: b.track, startClipID: b.startClipID,
                           day: startDay(b), used: b.end - b.start,
                           total: durations[b.track.fileName],
                           onRestore: { restoreFullLength(b) },
                           onRemove: {
                               let next = neighborToSelect(after: b, in: blocks)
                               store.setAudioTrack(nil, onClip: b.startClipID)
                               selected = next
                           })
                .id(b.track.id)
                .frame(width: 300)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.tap").font(.title2).foregroundStyle(.secondary)
                Text("Select a track to rename it, change its volume, or remove it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(width: 300)
            .frame(maxHeight: .infinity)
        }
    }

    /// The calendar day a track starts on (its start clip's date).
    private func startDay(_ b: Block) -> Date? {
        store.clips.first(where: { $0.id == b.startClipID })?.date
    }

    /// The track to select after removing `b`: the following one, or the previous
    /// one when `b` is the last in the list (nil if it was the only track).
    private func neighborToSelect(after b: Block, in blocks: [Block]) -> UUID? {
        guard let i = blocks.firstIndex(where: { $0.track.id == b.track.id }) else { return nil }
        if i + 1 < blocks.count { return blocks[i + 1].track.id }
        if i > 0 { return blocks[i - 1].track.id }
        return nil
    }

    /// Extends a track back to its full original file length, clamped so it can't
    /// overlap the next track or run past the timeline. Returns a warning message
    /// when a following track cut the restore short, else nil. A no-op (nil) when
    /// the file duration isn't loaded yet or the track is already at full length.
    private func restoreFullLength(_ b: Block) -> String? {
        let l = store.timelineLayout()
        let full = b.start + fileLength(b)                              // audible end if the whole file played
        let hi = neighborBounds(b, blocks: audioBlocks(l), total: l.total).hi
        let target = min(full, hi)
        guard target > (b.end + 0.05) else {                           // already as long as it can be
            return hi < full - 0.05 && hi < l.total - 0.05
                ? "This track already reaches the next track — can't make it any longer."
                : nil
        }
        let (eClip, eWithin) = endAnchor(atSeconds: target, layout: l)
        store.moveAudioTrack(b.track.id, toStartClip: b.startClipID,
                             offset: b.track.offsetSeconds, endClipID: eClip, endWithin: eWithin)
        // Warn when a following track (not just the timeline end) held it back.
        if hi < full - 0.05 && hi < l.total - 0.05 {
            return "The next track was in the way, so this was restored only as far as it fits."
        }
        return nil
    }

    /// Scrolls the timeline so the selected song's block is visible — but only
    /// when it isn't already on screen, so clicking a block that's already in
    /// view (in the lane) doesn't yank the scroll around.
    private func revealTrack(_ id: UUID?) {
        guard let id,
              let b = audioBlocks(store.timelineLayout()).first(where: { $0.track.id == id })
        else { return }
        let x0 = xPos(b.start), x1 = xPos(b.end)
        guard x0 < visibleLeft + 8 || x1 > visibleRight - 8 else { return }   // already fully visible
        scrollPosition.scrollTo(x: max(0, x0 - 60))
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

    /// Timeline start (render seconds) of the clip owning `selectTrackID`, so an
    /// opened-from-the-day-window track scrolls precisely into view. Nil when no
    /// track is requested or it can't be located.
    private func selectedTrackStartSeconds() -> Double? {
        guard let selectTrackID,
              let owner = store.clips.first(where: { $0.audio?.id == selectTrackID }) else { return nil }
        return store.timelineLayout().startByID[owner.id]
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
            let raw = max(0, base.start + dsec)
            // Reorder freely: the song can leap over its neighbours into any free
            // gap big enough to hold it (its own current gap always qualifies), so
            // dragging one song past another moves it there instead of stopping at
            // the neighbour. The gap chosen is the one whose nearest fitting start
            // is closest to where the drag has reached, so it flips to the far side
            // once the drag passes the midway point.
            let gaps = freeGaps(excluding: base, blocks: blocks, total: l.total)
                .filter { $0.end - $0.start >= len - 1e-6 }
            guard let gap = gaps.min(by: {
                abs(min(max(raw, $0.start), $0.end - len) - raw) <
                abs(min(max(raw, $1.start), $1.end - len) - raw)
            }) else { return (base.start, base.end) }
            var ns = min(max(raw, gap.start), gap.end - len)
            // Snap whichever edge (start or end) is nearest a day/clip line.
            let s = snap(ns, to: lines, within: snapSec)
            let e = snap(ns + len, to: lines, within: snapSec)
            if let s, let e { ns = abs(s - ns) <= abs(e - (ns + len)) ? s : e - len }
            else if let s { ns = s }
            else if let e { ns = e - len }
            ns = min(max(ns, gap.start), gap.end - len)
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
    /// neighbouring block (or the timeline ends) — used to forbid overlap on the
    /// edge-resize drags (which don't reorder).
    private func neighborBounds(_ base: Block, blocks: [Block], total: Double) -> (lo: Double, hi: Double) {
        var lo = 0.0
        var hi = total
        for o in blocks where o.track.id != base.track.id {
            if o.end <= base.start { lo = max(lo, o.end) }
            if o.start >= base.end { hi = min(hi, o.start) }
        }
        return (lo, hi)
    }

    /// The empty stretches on the timeline (in seconds) once every block *except*
    /// `base` is placed — i.e. every spot `base` could be dropped without
    /// overlapping. Used by the body drag so a song can move into a gap on the
    /// far side of another song. `base`'s own current gap is always one of them.
    private func freeGaps(excluding base: Block, blocks: [Block], total: Double) -> [(start: Double, end: Double)] {
        let occupied = blocks.filter { $0.track.id != base.track.id }
            .map { (start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
        var gaps: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for o in occupied {
            if o.start > cursor + 1e-6 { gaps.append((cursor, o.start)) }
            cursor = max(cursor, o.end)
        }
        if total > cursor + 1e-6 { gaps.append((cursor, total)) }
        return gaps
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
        let track = AudioTrack(fileName: name, displayName: url.deletingPathExtension().lastPathComponent,
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

// MARK: - Track inspector

/// Editor for the selected track: rename, see how much of it plays vs. its full
/// length, restore it to full length, set volume, remove. The name is a local
/// draft that commits on Return or when the field loses focus (not on every
/// keystroke), and edits `AudioTrack.displayName` so the user can give a track a
/// friendlier name than its imported file name.
private struct TrackInspector: View {
    @EnvironmentObject var store: LibraryStore
    let track: AudioTrack
    let startClipID: UUID
    let day: Date?
    /// How much of the track plays here (its span on the timeline).
    let used: Double
    /// Full length of the audio file, nil until it's been measured.
    let total: Double?
    /// Restores the track to full length; returns a warning if it couldn't.
    let onRestore: () -> String?
    let onRemove: () -> Void

    @State private var nameDraft: String = ""
    @State private var restoreWarning: String?
    @FocusState private var nameFocused: Bool

    /// Whether the track already plays its whole file (within a small tolerance),
    /// so restoring would do nothing.
    private var atFullLength: Bool {
        guard let total else { return false }
        return used >= total - 0.05
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Track").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Track name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commitName)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let day {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                        Text(day.formatted(date: .abbreviated, time: .omitted))
                    }
                    .font(.callout)
                }
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    if let total {
                        Text("Plays \(formatDurationShort(used)) of \(formatDurationShort(total))")
                    } else {
                        Text("Plays \(formatDurationShort(used))")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Volume").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                    Slider(value: volumeBinding, in: 0...4)
                    Text("\(Int((track.volume * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Button { restoreWarning = onRestore() } label: {
                    Label("Restore Full Length", systemImage: "arrow.uturn.backward")
                }
                .disabled(total == nil || atFullLength)
                if let restoreWarning {
                    Label(restoreWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Label("Remove Track", systemImage: "trash")
            }
        }
        .padding(14)
        .onAppear { nameDraft = track.label }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { track.volume }, set: { v in
            var t = track; t.volume = v
            store.setAudioTrack(t, onClip: startClipID)
        })
    }

    /// Commits the renamed title to the track's `displayName`. An empty name is
    /// ignored (reverts to the current label), and the write is skipped when the
    /// track no longer exists on its clip (it was just removed) so a focus-loss
    /// commit can't re-add a deleted track.
    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { nameDraft = track.label; return }
        guard trimmed != track.label,
              store.clips.first(where: { $0.id == startClipID })?.audio?.id == track.id else { return }
        var t = track; t.displayName = trimmed
        store.setAudioTrack(t, onClip: startClipID)
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
