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
/// the same positions the exporter renders, so the lane is WYSIWYG. The
/// selected track's inspector adds the file-space counterpart: a trim bar
/// (`AudioTrimBar`) choosing *which part of the song* plays over that span.
struct SoundtrackView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    /// The day to land near (see `SoundtrackRequest`).
    let anchorDate: Date
    /// A track to pre-select and scroll to on open (see `SoundtrackRequest`).
    var selectTrackID: UUID? = nil

    /// Horizontal scale: points per second of timeline.
    @State private var pps: Double = 30
    @State private var selected: UUID?
    @State private var waveforms: [String: [Float]] = [:]
    @State private var durations: [String: Double] = [:]
    @State private var showImporter = false
    @State private var addAtSeconds: Double?
    /// A message for this window's own alert — errors from interactions here
    /// (add refused, copy failed) must surface over *this* window; the store's
    /// `lastError` alert is attached to the main calendar window, which can be
    /// behind or on another screen.
    @State private var errorMessage: String?
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
            header(grid: grid)
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
               minHeight: 460, idealHeight: 680, maxHeight: .infinity, alignment: .top)
        .background {
            Button("Close") { dismiss() }
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
        .alert("Can't Add Music", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private func header(grid: LibraryStore.TimelineGrid) -> some View {
        let visibleDays = visibleDayRange(grid)
        return HStack(spacing: 12) {
            Spacer()
            Button { previewVisibleDays() } label: {
                Label(visibleDays.map { "Preview \(visibleDaysLabel($0))" } ?? "Preview",
                      systemImage: "play.fill")
            }
            .disabled(visibleDays == nil)
            .help("Preview the days on screen with their soundtrack — scroll to pick where, zoom to pick how much")
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
        // Viewport (not content) padding, so the clips/audio keep a small
        // margin from the window edge on both sides at any scroll position.
        .padding(.horizontal, 12)
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
                Text(knownDuration(of: b.track).map(formatDurationShort) ?? "—")
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
            // How far the audible edges can move before hitting a neighbouring
            // track or the timeline ends — the trim bar clamps its edge drags
            // with these, mirroring the lane's edge-resize bounds. The start
            // additionally clamps to positions whose clip can anchor the track.
            let layout = store.timelineLayout()
            let bounds = neighborBounds(b, blocks: blocks, total: layout.total)
            let anchor = startAnchorBounds(b, layout: layout, bounds: bounds)
            TrackInspector(track: b.track, startClipID: b.startClipID,
                           day: startDay(b), used: b.end - b.start,
                           total: knownDuration(of: b.track),
                           waveform: waveforms[b.track.fileName] ?? [],
                           leftSlack: max(0, b.start - anchor.lo),
                           startRightSlack: max(0, anchor.hi - b.start),
                           rightSlack: max(0, bounds.hi - b.end),
                           onTrim: { applyTrim(b, $0) },
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
                Text("Select a track to rename it, trim it, change its volume, or remove it.")
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
        store.clip(withID: b.startClipID)?.date
    }

    /// The track to select after removing `b`: the following one, or the previous
    /// one when `b` is the last in the list (nil if it was the only track).
    private func neighborToSelect(after b: Block, in blocks: [Block]) -> UUID? {
        guard let i = blocks.firstIndex(where: { $0.track.id == b.track.id }) else { return nil }
        if i + 1 < blocks.count { return blocks[i + 1].track.id }
        if i > 0 { return blocks[i - 1].track.id }
        return nil
    }

    /// Extends a track back to its full original file length — clearing its
    /// trim-in point, so the whole song plays from its audible start — clamped
    /// so it can't overlap the next track or run past the timeline. Returns a
    /// warning message when a following track cut the restore short, else nil.
    /// A no-op (nil) when the file duration isn't loaded yet or the track
    /// already plays its whole file.
    private func restoreFullLength(_ b: Block) -> String? {
        let l = store.timelineLayout()
        // Audible end if the whole file played from the audible start (the
        // trim-in point is being reset, so the full duration counts).
        let full = b.start + (knownDuration(of: b.track) ?? (b.end - b.start))
        let hi = neighborBounds(b, blocks: audioBlocks(l), total: l.total).hi
        let target = min(full, hi)
        // `target` never falls below the current end (the file cap and the
        // neighbour bound both sit at or past it), so this only ever extends.
        guard target > (b.end + 0.05) || b.track.fileInPoint > 0.05 else {
            return hi < full - 0.05 && hi < l.total - 0.05
                ? "This track already reaches the next track — can't make it any longer."
                : nil
        }
        let (eClip, eWithin) = endAnchor(atSeconds: target, layout: l)
        store.moveAudioTrack(b.track.id, toStartClip: b.startClipID,
                             offset: max(0, b.track.offsetSeconds),
                             endClipID: eClip, endWithin: eWithin, fileStart: 0)
        // Warn when a following track (not just the timeline end) held it back.
        if hi < full - 0.05 && hi < l.total - 0.05 {
            return "The next track was in the way, so this was restored only as far as it fits."
        }
        return nil
    }

    /// Applies a trim-bar edit from the inspector. `.start`/`.end` move that
    /// edge of the audible span on the timeline (re-anchored through the same
    /// clip/offset math as the lane drags); `.slide` keeps the span exactly
    /// where it is and changes only which part of the file plays over it.
    private func applyTrim(_ b: Block, _ edit: AudioTrimBar.Edit) {
        let l = store.timelineLayout()
        switch edit {
        case .slide(let inPoint):
            // Pin the end exactly where it audibly is today (an open-ended or
            // file-capped span would otherwise grow when the slide frees up
            // more of the file) and swap the in-point under the fixed window.
            let (eClip, eWithin) = endAnchor(atSeconds: b.end, layout: l)
            store.moveAudioTrack(b.track.id, toStartClip: b.startClipID,
                                 offset: max(0, b.track.offsetSeconds),
                                 endClipID: eClip, endWithin: eWithin, fileStart: inPoint)
        case .start(let inPoint):
            // The audible start moves by the same amount as the in-point, so
            // every kept moment of the song stays where it was on the timeline
            // — trimming the head doesn't shift the rest against the picture.
            let newStart = b.start + (inPoint - b.track.fileInPoint)
            let (sClip, off) = clipAndOffset(atSeconds: newStart, layout: l)
            store.moveAudioTrack(b.track.id, toStartClip: sClip, offset: off,
                                 endClipID: b.track.endClipID,
                                 endWithin: b.track.endWithinSeconds, fileStart: inPoint)
        case .end(let used):
            let (eClip, eWithin) = endAnchor(atSeconds: b.start + used, layout: l)
            store.moveAudioTrack(b.track.id, toStartClip: b.startClipID,
                                 offset: b.track.offsetSeconds,
                                 endClipID: eClip, endWithin: eWithin)
        }
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

    /// Build the lane's blocks from the layout's resolved placements (the same
    /// spans the exporter renders, stale references repaired and overlaps
    /// clamped), capping each to its file's length. A track is **never
    /// dropped** here: one whose file is missing/unreadable (duration unknown
    /// or 0) or whose span collapsed still shows as a (possibly sliver-width)
    /// block, so it stays selectable and removable instead of sitting in
    /// clips.json with no UI to reach it.
    private func audioBlocks(_ l: LibraryStore.TimelineLayout) -> [Block] {
        l.tracks.map { placed in
            // An unknown/unreadable duration caps nothing — better a too-long
            // block than an invisible track.
            let fileCap = knownDuration(of: placed.track)
                .map { placed.start + max(0, $0 - placed.track.fileInPoint) } ?? placed.end
            let end = max(min(placed.end, fileCap), placed.start)
            return Block(track: placed.track, startClipID: placed.startClipID,
                         start: placed.start, end: end)
        }
    }

    /// Current display geometry for a block, applying any in-flight drag.
    private func geometry(_ base: Block, layout l: LibraryStore.TimelineLayout,
                          blocks: [Block]) -> (start: Double, end: Double) {
        guard let d = drag, d.id == base.track.id else { return (base.start, base.end) }
        let dsec = Double(d.dx) / pps
        let (lo, hi) = neighborBounds(base, blocks: blocks, total: l.total)
        let lines = l.boundaries
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

    /// The nearest line to `v` if within `within` seconds, else nil. `lines`
    /// is the layout's precomputed ascending boundary list (every clip start +
    /// the timeline end), so a binary search finds the neighbour pair — this
    /// runs on every drag tick, where a linear scan over thousands of clips
    /// added up.
    private func snap(_ v: Double, to lines: [Double], within: Double) -> Double? {
        guard !lines.isEmpty else { return nil }
        // Binary search: first index with lines[i] >= v.
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        var nearest = lo < lines.count ? lines[lo] : lines[lines.count - 1]
        if lo > 0, abs(lines[lo - 1] - v) < abs(nearest - v) { nearest = lines[lo - 1] }
        return abs(nearest - v) <= within ? nearest : nil
    }

    /// The timeline range the audible *start* may move within for the trim
    /// bar's left-edge drag. Beyond the previous block (`bounds.lo`), the
    /// start is bound by the one-track-per-clip rule: it can only sit on a
    /// clip that doesn't anchor another song — `moveAudioTrack` refuses such
    /// a commit and the whole drag would silently snap back. So walk outward
    /// from the current start clip: earlier free clips extend the floor, and
    /// the first anchor-owning clip in either direction is a wall (its very
    /// start, going right, since any position inside it would re-anchor
    /// there). Clamping the drag to this range makes the bar WYSIWYG — what
    /// it shows during the drag is what the release commits.
    private func startAnchorBounds(_ b: Block, layout l: LibraryStore.TimelineLayout,
                                   bounds: (lo: Double, hi: Double)) -> (lo: Double, hi: Double) {
        guard let idx = l.order.firstIndex(where: { $0.id == b.startClipID }) else {
            return (b.start, b.start)
        }
        var floor = l.startByID[b.startClipID] ?? 0
        var i = idx - 1
        while i >= 0, l.order[i].audio == nil {
            floor = l.startByID[l.order[i].id] ?? floor
            i -= 1
        }
        var ceiling = b.end
        var j = idx + 1
        while j < l.order.count {
            guard let s = l.startByID[l.order[j].id], s < ceiling else { break }
            if l.order[j].audio != nil { ceiling = max(b.start, s - 0.001); break }
            j += 1
        }
        return (max(bounds.lo, floor), ceiling)
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
        let full = knownDuration(of: b.track) ?? (b.end - b.start)
        return max(0.2, full - b.track.fileInPoint)
    }

    /// The track's file length: the asset-loaded value once it lands, else the
    /// duration measured when the file was added (`nil` for legacy tracks
    /// until the load finishes; 0/unreadable never counts).
    private func knownDuration(of track: AudioTrack) -> Double? {
        let d = durations[track.fileName] ?? track.fileDurationSeconds
        return (d ?? 0) > 0.05 ? d : nil
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

    /// The first…last calendar days whose timeline span is scrolled into view
    /// (at least a pixel on screen) — what the Preview button renders and names,
    /// so the preview is WYSIWYG with the lane: scroll to choose where, zoom to
    /// choose how long a stretch. Nil only when there are no days (empty
    /// project).
    private func visibleDayRange(_ grid: LibraryStore.TimelineGrid) -> (start: Date, end: Date)? {
        let visible = grid.days.filter { xPos($0.end) > visibleLeft + 1 && xPos($0.start) < visibleRight - 1 }
        guard let first = visible.first, let last = visible.last,
              let s = Double(first.key), let e = Double(last.key) else { return nil }
        return (Date(timeIntervalSinceReferenceDate: s), Date(timeIntervalSinceReferenceDate: e))
    }

    /// Compact live label for the days on screen: "Jun 12" for a single day,
    /// else an interval like "Jun 12 – 28" / "Jun 28 – Jul 3".
    private func visibleDaysLabel(_ days: (start: Date, end: Date)) -> String {
        guard days.start != days.end else {
            return days.start.formatted(.dateTime.month(.abbreviated).day())
        }
        return (days.start..<days.end).formatted(.interval.month(.abbreviated).day())
    }

    /// Previews the days currently on screen (whole calendar days — the
    /// partially visible edge days count), first dismissing any existing preview
    /// of the same span so it always rebuilds from the current arrangement (and
    /// restarts from the start) instead of refocusing a stale window.
    private func previewVisibleDays() {
        guard let days = visibleDayRange(store.timelineGrid()) else { return }
        let req = PreviewRequest(range: .custom(start: days.start, end: days.end))
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
        let (clipID, _) = clipAndOffset(atSeconds: sec, layout: l)
        // Don't clobber a clip that already starts a song (a clip starts at most
        // one; a long clip can have free lane space beside a song it already
        // owns). Tell the user why nothing appeared instead of failing silently
        // — in *this* window: the store's lastError alert hangs off the main
        // calendar window, which may be behind or on another screen.
        guard store.clip(withID: clipID)?.audio == nil else {
            errorMessage = "A song already starts on that clip, and a clip can "
                + "only start one. Click over a different clip, or remove the other song first."
            return
        }
        guard let name = store.copyAudioFile(from: url) else {
            // Surface the copy failure here too, not on the main window.
            errorMessage = store.lastError
            store.lastError = nil
            return
        }
        // The new song fits the clicked clip: it starts at the clip's start —
        // not at the exact click position — and ends with the clip. If an
        // earlier song's tail spills into this clip, start where that tail
        // ends instead, so blocks never overlap.
        let clipStart = l.startByID[clipID] ?? 0
        let tailEnd = audioBlocks(l).map(\.end).filter { $0 <= sec }.max() ?? 0
        let track = AudioTrack(fileName: name, displayName: url.deletingPathExtension().lastPathComponent,
                               offsetSeconds: max(0, tailEnd - clipStart), endClipID: clipID,
                               fileDurationSeconds: store.measuredAudioDuration(ofFileNamed: name))
        store.setAudioTrack(track, onClip: clipID)
        selected = track.id
    }

    // MARK: - Waveforms

    private func waveformSlice(_ b: Block, geometry g: (start: Double, end: Double)) -> [Float] {
        guard let full = waveforms[b.track.fileName], !full.isEmpty,
              let dur = durations[b.track.fileName], dur > 0 else { return [] }
        let inPoint = b.track.fileInPoint
        let to = inPoint + (g.end - g.start)
        let n = full.count
        let i0 = max(0, min(n - 1, Int(inPoint / dur * Double(n))))
        let i1 = max(i0 + 1, min(n, Int(to / dur * Double(n))))
        return Array(full[i0..<i1])
    }

    /// Fills the waveform/duration dictionaries for any block missing one, all
    /// files concurrently, through the store's decoded-waveform cache — so a
    /// window reopened on the same project doesn't decode anything twice, and
    /// several songs load in roughly the time of the longest, not the sum.
    private func loadMissingWaveforms(_ blocks: [Block]) async {
        let missing = blocks.map(\.track).filter { waveforms[$0.fileName] == nil }
        guard !missing.isEmpty else { return }
        let store = self.store
        let results = await withTaskGroup(
            of: (String, [Float], Double).self,
            returning: [(String, [Float], Double)].self
        ) { group in
            for track in missing {
                group.addTask { @MainActor in
                    let (wf, dur) = await store.audioWaveform(for: track, buckets: 1200)
                    return (track.fileName, wf, dur)
                }
            }
            var collected: [(String, [Float], Double)] = []
            for await r in group { collected.append(r) }
            return collected
        }
        for (name, wf, dur) in results {
            waveforms[name] = wf
            durations[name] = dur
        }
    }

}

// MARK: - Track inspector

/// Editor for the selected track: rename, see how much of it plays vs. its full
/// length, trim which part of the file plays (the trim bar), listen to just
/// that part, restore it to full length, set volume, remove. The name is a
/// local draft that commits on Return or when the field loses focus (not on
/// every keystroke), and edits `AudioTrack.displayName` so the user can give a
/// track a friendlier name than its imported file name.
private struct TrackInspector: View {
    @EnvironmentObject var store: LibraryStore
    let track: AudioTrack
    let startClipID: UUID
    let day: Date?
    /// How much of the track plays here (its span on the timeline).
    let used: Double
    /// Full length of the audio file, nil until it's been measured.
    let total: Double?
    /// The whole file's waveform for the trim bar (empty while loading).
    let waveform: [Float]
    /// Timeline seconds the audible start/end can still move outward before
    /// hitting a neighbouring track, the timeline ends, or (for the start) a
    /// clip that anchors another song (trim-bar clamps).
    let leftSlack: Double
    /// Timeline seconds the audible start may move *right* before landing on
    /// a clip that anchors another song.
    let startRightSlack: Double
    let rightSlack: Double
    /// Commits a trim-bar drag (see `AudioTrimBar.Edit`).
    let onTrim: (AudioTrimBar.Edit) -> Void
    /// Restores the track to full length; returns a warning if it couldn't.
    let onRestore: () -> String?
    let onRemove: () -> Void

    @State private var nameDraft: String = ""
    /// Live slider value; committed to the store only when the drag ends —
    /// every commit rewrites the whole library file, so not per tick.
    @State private var volumeDraft: Double = 1.0
    @State private var restoreWarning: String?
    @FocusState private var nameFocused: Bool
    /// The "Listen" preview of just the trimmed part: a standalone player
    /// (nil when idle) plus a 30 Hz timer that moves the bar's playhead and
    /// stops the player at the window's end (AVAudioPlayer has no stop-at).
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewTimer: Timer?
    @State private var previewPlayhead: Double?
    /// Trim-bar magnification, 1 = the whole file fits the bar. Resets when
    /// another track is selected (the inspector is identity-keyed per track).
    @State private var trimZoom: CGFloat = 1

    /// Whether the track already plays its whole file (within a small tolerance),
    /// so restoring would do nothing.
    private var atFullLength: Bool {
        guard let total else { return false }
        return used >= total - 0.05
    }

    var body: some View {
        // The form scrolls when the window is short (the trim bar made it
        // taller than the smallest window); Remove stays pinned below it.
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Track").font(.headline)
                        Spacer()
                        if let day {
                            HStack(spacing: 5) {
                                Image(systemName: "calendar")
                                Text(day.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.caption).foregroundStyle(.secondary)
                        TextField("Track name", text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onSubmit(commitName)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Volume").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                            Slider(value: $volumeDraft, in: 0...4) { editing in
                                if !editing { commitVolume() }
                            }
                            Text("\(Int((volumeDraft * 100).rounded()))%")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                    }

                    trimSection

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
                }
                .padding(14)
            }

            Divider()

            Button(role: .destructive, action: onRemove) {
                Label("Remove Track", systemImage: "trash")
            }
            .padding(14)
        }
        .onAppear { nameDraft = track.label; volumeDraft = track.volume }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
        // A lane drag (or any other edit) can change the trimmed window while
        // it's playing — stop rather than keep playing a stale selection. Also
        // covers deselection/removal via onDisappear.
        .onChange(of: track) { _, _ in stopPreview() }
        .onDisappear { stopPreview() }
    }

    /// The trim bar and its "Listen" button: the whole file's waveform with a
    /// yellow window over the part that plays, mirroring the video trim slider.
    /// The −/+ buttons zoom the bar (the timeline header's idiom) so a
    /// few-second window on a long song gets enough pixels to trim precisely;
    /// the bar re-centers on the window at each step.
    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Trim").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { trimZoom = max(1, trimZoom / 2) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(total == nil || trimZoom <= 1)
                .help("Zoom out the trim bar")
                Button { trimZoom = min(64, trimZoom * 2) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(total == nil || trimZoom >= 64)
                .help("Zoom in on the trimmed part for finer adjustments")
                Button { togglePreview() } label: {
                    Label(previewPlayer == nil ? "Listen" : "Stop",
                          systemImage: previewPlayer == nil ? "play.fill" : "stop.fill")
                }
                .controlSize(.small)
                .disabled(total == nil)
                .help("Play just the trimmed part of the song")
            }
            if let total, total > 0.05 {
                AudioTrimBar(waveform: waveform, fileDuration: total,
                             inPoint: track.fileInPoint, used: used,
                             leftSlack: leftSlack, startRightSlack: startRightSlack,
                             rightSlack: rightSlack,
                             playhead: previewPlayhead, zoom: trimZoom,
                             onDragStarted: { stopPreview() },
                             onEdit: { stopPreview(); onTrim($0) })
            } else {
                // Same footprint as the loaded bar, so nothing jumps.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 64)
                    .overlay(Text("Loading waveform…").font(.caption).foregroundStyle(.secondary))
            }
        }
    }

    /// Plays exactly the trimmed window (in-point → in-point + used length) at
    /// the track's volume, or stops an ongoing preview — the audible check that
    /// the yellow window sits where the user thinks it does.
    private func togglePreview() {
        guard previewPlayer == nil else { stopPreview(); return }
        guard let p = try? AVAudioPlayer(contentsOf: store.audioURL(for: track)) else { return }
        // Like the editors' previews, tops out at 100%; a boost still renders.
        p.volume = Float(min(1, max(0, track.volume)))
        let start = track.fileInPoint
        let end = min(p.duration, start + used)
        guard end > start else { return }
        p.currentTime = start
        p.play()
        previewPlayer = p
        previewPlayhead = start
        // Added in `.common` mode (not `scheduledTimer`'s default-only), so the
        // playhead keeps moving — and the stop-at-end keeps firing — during
        // event tracking (a window resize, an open menu, a drag elsewhere).
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            guard let playing = previewPlayer else { return }
            if !playing.isPlaying || playing.currentTime >= end - 0.02 {
                stopPreview()
            } else {
                previewPlayhead = playing.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewPlayhead = nil
    }

    /// Commits the released slider value, skipped when the track no longer
    /// exists on its clip (just removed) so the write can't re-add it.
    private func commitVolume() {
        guard volumeDraft != track.volume,
              store.clip(withID: startClipID)?.audio?.id == track.id else { return }
        var t = track; t.volume = volumeDraft
        store.setAudioTrack(t, onClip: startClipID)
    }

    /// Commits the renamed title to the track's `displayName`. An empty name is
    /// ignored (reverts to the current label), and the write is skipped when the
    /// track no longer exists on its clip (it was just removed) so a focus-loss
    /// commit can't re-add a deleted track.
    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { nameDraft = track.label; return }
        guard trimmed != track.label,
              store.clip(withID: startClipID)?.audio?.id == track.id else { return }
        var t = track; t.displayName = trimmed
        store.setAudioTrack(t, onClip: startClipID)
    }
}

// MARK: - Trim bar

/// The inspector's trim control: the whole audio file's waveform with a
/// draggable yellow window over the part that plays — the video trim slider's
/// look, applied to a song. Dragging the **left edge** trims where the song
/// starts: the audible start moves by the same amount on the timeline, so
/// every kept moment stays in sync with the picture. The **right edge** sets
/// where it stops (the lane's edge drag, with the file visible). Dragging the
/// **window body** slides which part of the song plays — same length, the
/// block on the timeline doesn't move at all. Drags clamp to the file, a
/// minimum length, and the passed timeline slacks (the room before a
/// neighbouring track). All values are file seconds; commits fire on release.
///
/// Hit-testing is one gesture over the whole bar: where the press *starts*
/// picks the drag — a handle (small margin) wins, else anywhere on the yellow
/// square slides it. A short span over a whole song draws only a sliver of a
/// square — the common case here — so below a width threshold the handles
/// move *outside* the square, keeping every pixel of the square itself a
/// slide target instead of letting the handles swallow it. Hover cursors
/// telegraph the zones. `zoom` (the inspector's −/+ buttons) stretches the
/// file across that many viewports inside a horizontal scroll — panned by
/// dragging the strip's empty parts (`.pan`) or a trackpad scroll, and
/// re-centered on the window at every zoom step — so even a seconds-long
/// window on a long song gets enough pixels to trim precisely. When the
/// system uses legacy (space-taking) scroll bars, the bar reserves the
/// scroller's height beneath itself (`scrollerPad`) so the scroll bar gets
/// its own strip instead of squeezing the waveform into the views above.
private struct AudioTrimBar: View {
    /// A committed drag, in file terms.
    enum Edit {
        /// Body dragged: new in-point, same length — the timeline span stays.
        case slide(inPoint: Double)
        /// Left edge dragged: new in-point; the audible start follows it.
        case start(inPoint: Double)
        /// Right edge dragged: new played length; the audible end follows it.
        case end(used: Double)
    }

    let waveform: [Float]
    let fileDuration: Double
    /// The committed window: where in the file play starts, and for how long.
    let inPoint: Double
    let used: Double
    /// Timeline room the audible start/end may still move into before hitting
    /// a neighbouring track, the timeline ends, or a clip that can't anchor
    /// the track (the commit would be refused and the drag would snap back).
    let leftSlack: Double
    /// Room for the audible start to move *right* (a left-edge trim) before
    /// landing on a clip that anchors another song.
    let startRightSlack: Double
    let rightSlack: Double
    /// File position of the Listen playhead; nil hides it.
    var playhead: Double?
    /// Magnification: 1 = the whole file fits the bar; higher stretches the
    /// file across `zoom` viewports (panned by dragging its empty parts, or
    /// a trackpad scroll), so a short window on a long song gets enough
    /// pixels to trim precisely.
    var zoom: CGFloat = 1
    /// Fired when a drag begins, so the inspector can stop its preview.
    let onDragStarted: () -> Void
    let onEdit: (Edit) -> Void

    private enum Mode { case body, left, right, pan }
    /// In-flight drag: its mode, the press x that started it (a gesture's
    /// `startLocation` never changes, so a *different* one means a stale
    /// entry from a cancelled gesture — start fresh), and the live dx.
    @State private var drag: (mode: Mode, startX: CGFloat, dx: CGFloat)?
    @State private var scroll = ScrollPosition()
    /// Live scroll offset (tracked so drag locations — measured in the
    /// scroll viewport's stable space — convert to file coordinates).
    @State private var scrollX: CGFloat = 0
    /// Scroll offset when an in-flight `.pan` drag began.
    @State private var panOrigin: CGFloat = 0
    /// Bumped when the system scroller style changes, purely to re-render
    /// (the body re-reads `NSScroller.preferredScrollerStyle`).
    @State private var scrollerStyleTick = 0

    /// The scroll viewport's coordinate space: drags are measured here (it
    /// never moves) rather than in the content's space, which slides under
    /// the pointer during a `.pan` and would feed back into the translation.
    private static let viewportSpace = "AudioTrimBar.viewport"

    private let barHeight: CGFloat = 44
    private let handleWidth: CGFloat = 10
    /// The hit gutter past each end of the file, riding *inside* the scroll
    /// content so a narrow window's outside handles stay visible and
    /// grabbable even when the window sits at the file's very ends.
    private let hitPad: CGFloat = 16
    /// Minimum window length, matching the lane's edge-drag clamp.
    private let minGap = 0.2
    /// Below this drawn width the handles move outside the square (see the
    /// type comment): wide enough that inside handles always leave a
    /// comfortably grabbable middle.
    private let narrowBelow: CGFloat = 56

    /// Extra height reserved under the bar for the horizontal scroll bar: a
    /// *legacy*-style scroller (mouse connected, or scroll bars set to
    /// Always) takes real layout space inside the ScrollView, so without a
    /// reservation it squeezes the bar out of its 44 pt and over the
    /// neighbouring views. Overlay scrollers (and 1×, where nothing scrolls)
    /// take none, so the section stays tight there. The bar content itself is
    /// *not* force-framed to the reserved height — it stays 44 pt, top-aligned
    /// into whatever the scroller leaves — which is what went wrong the first
    /// time this was tried: a forced taller content got centered against the
    /// scroller-reduced viewport and spilled out the top, over the buttons.
    private var scrollerPad: CGFloat {
        guard zoom > 1, NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    var body: some View {
        let pad = scrollerPad
        GeometryReader { geo in
            let viewportW = geo.size.width
            // Pixels for the whole file: gutters are part of the content, so
            // at 1× (content exactly fits the viewport) nothing scrolls.
            let fileW = max(50, (viewportW - hitPad * 2)) * zoom
            let win = window(width: fileW)
            VStack(alignment: .leading, spacing: 3) {
                ScrollView(.horizontal) {
                    bar(win, width: fileW)
                        .padding(.horizontal, hitPad)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                    scrollX = x
                }
                .frame(width: viewportW, height: barHeight + pad)
                .coordinateSpace(name: Self.viewportSpace)
                .onChange(of: zoom) { _, _ in recenter(viewportW: viewportW) }
                // Live while dragging: where in the file the window sits, and
                // how much of the song plays.
                HStack {
                    Text("\(formatDurationShort(win.start)) – \(formatDurationShort(win.end))")
                    Spacer()
                    Text("\(formatDurationShort(win.end - win.start)) of \(formatDurationShort(fileDuration))")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(height: barHeight + 20 + pad)
        // Re-render when the system flips between overlay and legacy
        // scrollers (mouse plugged/unplugged), so the reservation follows.
        .onReceive(NotificationCenter.default.publisher(
            for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyleTick &+= 1
        }
    }

    /// Scrolls so the (committed) window is centered — called on each zoom
    /// step, so zooming in homes in on the part being trimmed instead of
    /// drifting toward the file's head. Deferred a tick so the new content
    /// width is laid out before the scroll target resolves.
    private func recenter(viewportW: CGFloat) {
        let fileW = max(50, (viewportW - hitPad * 2)) * zoom
        let c = committedWindow
        let centerX = x((c.start + c.end) / 2, width: fileW) + hitPad
        let target = min(max(0, centerX - viewportW / 2),
                         max(0, fileW + hitPad * 2 - viewportW))
        DispatchQueue.main.async { scroll.scrollTo(x: target) }
    }

    private func bar(_ win: (start: Double, end: Double), width: CGFloat) -> some View {
        let g = geometry(for: win, width: width)
        return ZStack(alignment: .topLeading) {
            WaveformView(samples: waveform)
                .padding(.vertical, 3).padding(.horizontal, 2)
                .frame(width: width, height: barHeight)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Dimmed (cut) head and tail, like the video trim slider — up to
            // the drawn square (never inside it, even when it's wider than the
            // true window; the labels below carry the exact numbers).
            Rectangle().fill(.black.opacity(0.55))
                .frame(width: max(0, g.borderX), height: barHeight)
            Rectangle().fill(.black.opacity(0.55))
                .frame(width: max(0, width - g.borderX - g.borderW), height: barHeight)
                .offset(x: g.borderX + g.borderW)

            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: g.borderW, height: barHeight)
                .offset(x: g.borderX)

            if let playhead {
                Rectangle().fill(.white)
                    .frame(width: 2, height: barHeight)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(x: x(playhead, width: width) - 1)
            }

            handle.offset(x: g.leftHandleX)
            handle.offset(x: g.rightHandleX)
        }
        .frame(width: width, height: barHeight)
        // One gesture for the whole bar; the hit area reaches a little past
        // the ends so a narrow window's outside handles — which sit in the
        // inspector's padding gutter at the bar's edges — stay grabbable.
        .contentShape(Path(CGRect(x: -(handleWidth + 6), y: 0,
                                  width: width + (handleWidth + 6) * 2, height: barHeight)))
        .gesture(barDrag(width: width))
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverCursor(atX: p.x, width: width).set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    private var handle: some View {
        // The video trim slider's grip (shared `TrimHandle`), sized for this bar.
        TrimHandle(width: handleWidth, height: barHeight, slitHeight: 14)
    }

    /// The drawn square and handle positions for `win`. The square tracks the
    /// *true* window (only a hair of a floor so a sliver stays visible) —
    /// never a padded stand-in, so dragging one edge can't appear to move the
    /// other. Whether the handles sit inside its ends (wide) or just outside
    /// them (narrow) follows the *committed* width — not the mid-drag one —
    /// so they don't flip sides during a drag.
    private struct BarGeometry {
        var borderX: CGFloat
        var borderW: CGFloat
        var leftHandleX: CGFloat
        var rightHandleX: CGFloat
        var narrow: Bool
    }

    private func geometry(for win: (start: Double, end: Double), width: CGFloat) -> BarGeometry {
        let inX = x(win.start, width: width)
        let outX = x(win.end, width: width)
        let borderW = max(6, outX - inX)
        let borderX = max(0, min(inX, width - borderW))
        let c = committedWindow
        let narrow = x(c.end, width: width) - x(c.start, width: width) < narrowBelow
        return BarGeometry(
            borderX: borderX, borderW: borderW,
            leftHandleX: narrow ? borderX - handleWidth - 1 : borderX,
            rightHandleX: narrow ? borderX + borderW + 1 : borderX + borderW - handleWidth,
            narrow: narrow
        )
    }

    /// Which drag a press at `px` (file space) begins, from the committed
    /// geometry: a handle (with a small margin) wins, else anywhere on the
    /// yellow square slides it; the rest of the strip pans the zoomed view.
    /// On a narrow square the handle zones reach only *outward*, so they
    /// can't swallow the sliver of square between them.
    private func mode(atX px: CGFloat, width: CGFloat) -> Mode? {
        let g = geometry(for: committedWindow, width: width)
        let inward: CGFloat = g.narrow ? 0 : 4
        if px >= g.leftHandleX - 4, px <= g.leftHandleX + handleWidth + inward { return .left }
        if px >= g.rightHandleX - inward, px <= g.rightHandleX + handleWidth + 4 { return .right }
        if px >= g.borderX - 2, px <= g.borderX + g.borderW + 2 { return .body }
        return zoom > 1 ? .pan : nil
    }

    /// The pointer shape telegraphing what a press would do: resize arrows
    /// over the handles, an open hand over a slideable square or the pannable
    /// zoomed strip — plain when there's nothing to move.
    private func hoverCursor(atX px: CGFloat, width: CGFloat) -> NSCursor {
        switch mode(atX: px, width: width) {
        case .left, .right:
            return .resizeLeftRight
        case .body:
            let c = committedWindow
            return c.start > 0.01 || c.end < fileDuration - 0.01 ? .openHand : .arrow
        case .pan:
            return .openHand
        case nil:
            return .arrow
        }
    }

    /// One drag for the whole bar: the mode is picked from where the press
    /// landed on the first tick and held for the rest of the drag. Locations
    /// are measured in the scroll viewport's space (which never moves — the
    /// content itself slides during a `.pan`) and converted to file space
    /// with the scroll offset.
    private func barDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.viewportSpace))
            .onChanged { v in
                if let d = drag, d.startX == v.startLocation.x {
                    drag = (d.mode, d.startX, v.translation.width)
                } else if let m = mode(atX: v.startLocation.x + scrollX - hitPad, width: width) {
                    if m == .pan { panOrigin = scrollX }
                    onDragStarted()
                    drag = (m, v.startLocation.x, v.translation.width)
                } else {
                    drag = nil
                }
                if let d = drag, d.mode == .pan {
                    scroll.scrollTo(x: max(0, panOrigin - d.dx))
                }
            }
            .onEnded { v in
                guard let d = drag else { return }
                drag = (d.mode, d.startX, v.translation.width)
                commit(width: width)
            }
    }

    /// Turns the ended drag into an `Edit` — skipped when it didn't actually
    /// move anything (a stray click), so no pointless library write happens.
    private func commit(width: CGFloat) {
        guard let mode = drag?.mode else { return }
        let win = window(width: width)
        drag = nil
        let committed = window(width: width)   // drag cleared → the stored window
        guard abs(win.start - committed.start) > 0.005 || abs(win.end - committed.end) > 0.005
        else { return }
        switch mode {
        case .body: onEdit(.slide(inPoint: win.start))
        case .left: onEdit(.start(inPoint: win.start))
        case .right: onEdit(.end(used: win.end - win.start))
        case .pan: break   // moved the view, not the window — nothing to save
        }
    }

    /// The stored (not mid-drag) window, clamped inside the file.
    private var committedWindow: (start: Double, end: Double) {
        (min(inPoint, fileDuration), min(inPoint + used, fileDuration))
    }

    /// The displayed window: the committed values with any in-flight drag
    /// applied, clamped to the file, the minimum length, and the timeline
    /// slacks (so an edge can't push the block into a neighbouring track).
    private func window(width: CGFloat) -> (start: Double, end: Double) {
        let (s0, e0) = committedWindow
        guard let d = drag, width > 0, fileDuration > 0 else { return (s0, e0) }
        let dsec = Double(d.dx / width) * fileDuration
        switch d.mode {
        case .left:
            let lo = max(0, s0 - leftSlack)
            let hi = max(lo, min(e0 - minGap, s0 + startRightSlack))
            return (min(max(s0 + dsec, lo), hi), e0)
        case .right:
            let hi = min(fileDuration, e0 + rightSlack)
            return (s0, max(min(e0 + dsec, hi), min(hi, s0 + minGap)))
        case .body:
            let shift = max(-s0, min(dsec, fileDuration - e0))
            return (s0 + shift, e0 + shift)
        case .pan:
            return (s0, e0)   // scrolls the view; the window itself is untouched
        }
    }

    private func x(_ seconds: Double, width: CGFloat) -> CGFloat {
        guard fileDuration > 0 else { return 0 }
        return (CGFloat(min(max(0, seconds / fileDuration), 1)) * width).rounded()
    }
}

// MARK: - Clip strip cell

private struct ClipStripCell: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.openWindow) private var openWindow
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

    /// One filmstrip tile: the width of a single copy of the thumbnail, capped
    /// to a sensible box. A long clip *repeats* the frame across its cell (the
    /// stills idiom in NLE timelines) rather than stretching one frame — at
    /// high zoom that smears unrelated parts of the photo (background, edges)
    /// into what reads as separate content — or leaving a lone left-aligned
    /// thumbnail followed by dead space, which read as a gap in the timeline.
    /// A short clip's cell still just shrinks its single tile to fit.
    private var tileWidth: CGFloat { min(cellWidth, height * 1.4) }

    /// Tiles filling the cell (the last one clips at the cell's edge). Capped
    /// so an extremely long clip at maximum zoom doesn't materialize thousands
    /// of image views — past the cap the neutral background shows instead.
    private var tileCount: Int {
        guard tileWidth >= 1 else { return 1 }
        return min(64, max(1, Int((cellWidth / tileWidth).rounded(.up))))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            if let image {
                HStack(spacing: 0) {
                    ForEach(0..<tileCount, id: \.self) { _ in
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: tileWidth, height: height)
                            .clipped()
                    }
                }
            } else {
                Color.black.opacity(0.12)
            }
        }
        .frame(width: cellWidth, height: height, alignment: .topLeading)
        // Photo/video (or card) icon + duration, matching the calendar's
        // timeline thumbnails — only as much as fits one tile.
        .overlay(alignment: .bottomLeading) { kindBadge }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.15), lineWidth: 0.5))
        .contentShape(Rectangle())
        // Same as clicking the clip in the main window's timeline view: open
        // the day editor on this clip.
        .onTapGesture { openWindow(value: ReviewRequest(day: clip.date, startClipID: clip.id)) }
        .help("Edit \(clip.date.formatted(date: .abbreviated, time: .omitted))")
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
        if tileWidth >= 22 {
            HStack(spacing: 2) {
                Image(systemName: clip.isCard ? "rectangle.on.rectangle.angled"
                                              : (clip.kind == .photo ? "photo" : "video"))
                if tileWidth >= 52 {
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
