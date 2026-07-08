import SwiftUI
import UniformTypeIdentifiers
import AVKit

/// How the main window browses the project: the month `calendar` grid or the
/// continuous `timeline` of days. Stored in `@AppStorage` so the choice sticks.
enum MainViewMode: String { case calendar, timeline }

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var displayedMonth = Date().dayKey
    @AppStorage("mainViewMode") private var viewMode: MainViewMode = .calendar
    private enum ImportKind { case media, mash, dataExport }
    @State private var showImporter = false
    @State private var importKind: ImportKind = .media
    @State private var mashSource: MashSource?
    @State private var dataExportSource: DataExportSource?
    @State private var showRenderSheet = false
    @State private var showSourcesSheet = false
    @State private var showSettingsSheet = false
    @Environment(\.openWindow) private var openWindow
    @State private var tagFilter: String?
    /// The timeline's topmost visible day, tracked while in timeline mode so the
    /// Soundtrack opens on the same stretch of time the timeline is scrolled to.
    /// Not persisted (unlike `displayedMonth`); nil until the timeline reports.
    @State private var timelineTopDay: Date?
    @State private var showMonthPicker = false
    @State private var pickerYear = Calendar.current.component(.year, from: Date())
    /// Keyboard selection on the calendar grid: arrow keys move it, Return
    /// opens it. nil until the first arrow press (or a cell click) anchors it.
    @State private var selectedDay: Date?
    @FocusState private var calendarFocused: Bool

    private var calendar: Calendar { Calendar.current }

    /// File types the Import file panel accepts for the chosen kind: media
    /// files, a single 1SE mashup video, or a 1SE data-export folder.
    private var importContentTypes: [UTType] {
        switch importKind {
        case .media: return [.movie, .video, .mpeg4Movie, .quickTimeMovie, .image]
        case .mash: return [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        case .dataExport: return [.folder]
        }
    }

    var body: some View {
        Group {
            if store.hasProject {
                calendarBody
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .navigationTitle(store.currentProjectName ?? "ClipDiary")
        // Restore the last-viewed month for the open project, and follow along
        // when the project changes. Saving happens on every navigation below.
        .onAppear { restoreDisplayedMonth() }
        .onChange(of: store.currentProjectURL) { _, _ in restoreDisplayedMonth() }
        .onChange(of: displayedMonth) { _, newValue in
            guard store.hasProject, store.settings.lastViewedMonth != newValue else { return }
            store.updateSettings { $0.lastViewedMonth = newValue }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var calendarBody: some View {
        VStack(spacing: 0) {
            switch viewMode {
            case .calendar:
                monthHeader
                weekdayHeader
                calendarGrid
                    .focusable()
                    .focusEffectDisabled()
                    .focused($calendarFocused)
                    .onMoveCommand(perform: moveSelection)
                    .onKeyPress(.return) { openSelectedDay() }
                    .onKeyPress(.escape) {
                        guard selectedDay != nil else { return .ignored }
                        selectedDay = nil
                        return .handled
                    }
                    .onAppear {
                        // Focus the grid once it exists so arrow keys work
                        // right away (also on return from timeline mode).
                        DispatchQueue.main.async { calendarFocused = true }
                    }
            case .timeline:
                TimelineBody(displayedMonth: displayedMonth, tagFilter: tagFilter,
                             topVisibleDay: $timelineTopDay) { clip in
                    openWindow(value: ReviewRequest(day: clip.date, startClipID: clip.id))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $viewMode) {
                    Image(systemName: "calendar").tag(MainViewMode.calendar)
                    Image(systemName: "list.bullet.rectangle").tag(MainViewMode.timeline)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch between the month calendar and the timeline")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker(selection: $tagFilter) {
                    Text("All Clips").tag(String?.none)
                    ForEach(store.allTags, id: \.self) { tag in
                        Text(tag).tag(String?.some(tag))
                    }
                } label: {
                    Label("Filter by Tag",
                          systemImage: tagFilter == nil ? "tag" : "tag.fill")
                }
                .pickerStyle(.menu)
                .disabled(store.allTags.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                let undated = store.sourceItems.filter(\.isUndated).count
                if undated > 0 {
                    Button {
                        openWindow(value: ReviewRequest(day: displayedMonth, startUndated: true))
                    } label: {
                        Label("\(undated) undated", systemImage: "calendar.badge.exclamationmark")
                    }
                    .help("Review the photos and videos without a capture date (they have no embedded day, often stripped by chat apps)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettingsSheet = true } label: {
                    Label("Project Settings", systemImage: "gearshape")
                }
                .help("Project settings: video format and source folders (⌘,)")
                .keyboardShortcut(",", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Media…") { importKind = .media; showImporter = true }
                    Button("Import 1SE Video…") { importKind = .mash; showImporter = true }
                    Button("Import 1SE Data Export…") { importKind = .dataExport; showImporter = true }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: "cards") } label: {
                    Label("Cards", systemImage: "rectangle.on.rectangle.angled")
                }
                .help("Design and manage title cards (covers, endings, captioned slides)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Timeline mode → the day it's scrolled to; calendar mode
                    // (or the timeline before it's reported) → the start of the
                    // displayed month. Either way the soundtrack opens on the
                    // same stretch of time the main window is showing.
                    let monthStart = calendar.dateInterval(of: .month, for: displayedMonth)?.start
                        ?? displayedMonth
                    let anchor = viewMode == .timeline ? (timelineTopDay ?? monthStart) : monthStart
                    openWindow(value: SoundtrackRequest(anchorDate: anchor))
                } label: {
                    Label("Soundtrack", systemImage: "waveform")
                }
                .help("Lay background music over the clips on a timeline")
                .disabled(!store.hasClips())
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showRenderSheet = true } label: {
                    Label("Create Video…", systemImage: "film.stack")
                }
                .help("Pick a time range, then preview it or save the video")
                .disabled(!store.hasClips(taggedWith: tagFilter))
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: importKind == .media
        ) { result in
            guard case .success(let urls) = result else { return }
            switch importKind {
            case .media:
                Task {
                    for url in urls { await store.importMedia(from: url) }
                }
            case .mash:
                if let url = urls.first {
                    mashSource = MashSource(url: url)
                }
            case .dataExport:
                if let url = urls.first {
                    dataExportSource = DataExportSource(url: url)
                }
            }
        }
        .sheet(item: $mashSource) { source in
            MashImportSheet(sourceURL: source.url).environmentObject(store)
        }
        .sheet(item: $dataExportSource) { source in
            DataExportImportSheet(exportURL: source.url).environmentObject(store)
        }
        .onChange(of: store.allTags) { _, tags in
            if let tagFilter,
               !tags.contains(where: { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }) {
                self.tagFilter = nil
            }
        }
        .sheet(isPresented: $showRenderSheet) {
            let initialRange = store.settings.renderRange ?? .month(Date())
            RenderSheet(initialRange: initialRange,
                        tagFilter: tagFilter,
                        initialBookends: store.settings.bookends(for: initialRange))
                .environmentObject(store)
        }
        .sheet(isPresented: $showSourcesSheet) {
            SourceFoldersSheet().environmentObject(store)
        }
        .sheet(isPresented: $showSettingsSheet) {
            ProjectSettingsSheet().environmentObject(store)
        }
        // A freshly created project has neither clips nor sources — offer the
        // source-folder setup right away. onAppear covers arriving from the
        // welcome screen (where onChange can't fire: the calendar wasn't
        // installed yet); onChange covers switching projects in-place.
        .onAppear { offerSourcesSetupIfFresh() }
        .onChange(of: store.currentProjectURL) { _, _ in offerSourcesSetupIfFresh() }
    }

    private func offerSourcesSetupIfFresh() {
        if store.hasProject && store.clips.isEmpty && store.sourceFolders.isEmpty {
            showSourcesSheet = true
        }
    }

    // MARK: - Header

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Previous month (⌘←)")
            Button {
                pickerYear = calendar.component(.year, from: displayedMonth)
                showMonthPicker = true
            } label: {
                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.title2.bold())
                    .frame(minWidth: 220)
            }
            .buttonStyle(.plain)
            .help("Jump to any month or year")
            .popover(isPresented: $showMonthPicker, arrowEdge: .bottom) { monthYearPicker }
            Button { shiftMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Next month (⌘→)")
            Spacer()
            if let tagFilter {
                Text("Tag: \(tagFilter)")
                    .font(.callout.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.yellow.opacity(0.25)))
            }
            let monthClips = store.clips(inMonthOf: displayedMonth, taggedWith: tagFilter)
            if !monthClips.isEmpty {
                let total = monthClips.reduce(0) { $0 + $1.trimmedDuration }
                statChip("Picked") {
                    Label("\(monthClips.count) clips · \(formatDurationShort(total))",
                          systemImage: "film")
                        .monospacedDigit()
                }
                .help("Clips picked this month and their total running time")
            }

            let avail = store.availability(inMonthOf: displayedMonth)
            if !avail.isEmpty {
                statChip("To review") {
                    if avail.videoCount > 0 {
                        Label("\(avail.videoCount) · \(formatDurationShort(avail.videoDuration))",
                              systemImage: "video.fill")
                            .monospacedDigit()
                    }
                    if avail.photoCount > 0 {
                        Label("\(avail.photoCount)", systemImage: "photo.fill")
                    }
                }
                .help("Photos and videos available to review this month, from your source folders")
            }
        }
        .padding()
    }

    /// A labeled capsule for the month header's stats, so the number clusters
    /// read at a glance instead of needing the tooltip to tell them apart.
    private func statChip(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) { content() }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }

    /// Popover for jumping straight to any month/year: ‹ year › arrows over a
    /// 3×4 grid of months, plus a "This month" shortcut. Keeps the common
    /// prev/next-month chevrons untouched for one-step stepping.
    private var monthYearPicker: some View {
        let selectedYear = calendar.component(.year, from: displayedMonth)
        let selectedMonth = calendar.component(.month, from: displayedMonth)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return VStack(spacing: 12) {
            HStack {
                Button { pickerYear -= 1 } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(verbatim: String(pickerYear)).font(.headline.monospacedDigit())
                Spacer()
                Button { pickerYear += 1 } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    let isSelected = month == selectedMonth && pickerYear == selectedYear
                    Button {
                        jumpTo(year: pickerYear, month: month)
                        showMonthPicker = false
                    } label: {
                        Text(calendar.shortMonthSymbols[month - 1])
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.accentColor : Color.clear)
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            Button("This month") {
                displayedMonth = Date().dayKey
                showMonthPicker = false
            }
        }
        .padding()
        .frame(width: 260)
    }

    private var weekdayHeader: some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        return HStack {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    /// A bordered month grid that fills the available height: each week row
    /// (and each day within it) divides the space equally, so making the
    /// window taller makes the cells taller. Hairline separators between cells
    /// give it the look of a wall calendar.
    private var calendarGrid: some View {
        let weeks = weeksForDisplayedMonth()
        return VStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        Group {
                            if let day {
                                DayCell(
                                    day: day,
                                    tagFilter: tagFilter,
                                    isSelected: selectedDay.map { day.isSameDay(as: $0) } ?? false,
                                    onReview: { openWindow(value: ReviewRequest(day: day, focusSources: true)) },
                                    onEdit: {
                                        selectedDay = day
                                        openWindow(value: ReviewRequest(day: day))
                                    }
                                )
                                .environmentObject(store)
                            } else {
                                // Out-of-month padding: a faint gray wash over
                                // the cell background so these read as grayed
                                // out, not as empty days.
                                Color(nsColor: .controlBackgroundColor)
                                    .overlay(.quaternary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(
                            Rectangle()
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private func shiftMonth(by delta: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = newMonth
        }
    }

    /// Arrow-key navigation: ←/→ step a day, ↑/↓ a week, following across
    /// month edges. The first press only anchors the selection (today when
    /// its month is shown, else the 1st) without moving it.
    private func moveSelection(_ direction: MoveCommandDirection) {
        guard let current = selectedDay else {
            let today = Date().dayKey
            selectedDay = today.isSameMonth(as: displayedMonth)
                ? today
                : calendar.dateInterval(of: .month, for: displayedMonth)?.start
            return
        }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -7
        case .down: step = 7
        @unknown default: return
        }
        guard let next = calendar.date(byAdding: .day, value: step, to: current) else { return }
        selectedDay = next
        if !next.isSameMonth(as: displayedMonth) { displayedMonth = next.dayKey }
    }

    private func openSelectedDay() -> KeyPress.Result {
        guard let selectedDay else { return .ignored }
        openWindow(value: ReviewRequest(day: selectedDay))
        return .handled
    }

    /// Jump to the first day of the given year/month (used by the picker popover).
    private func jumpTo(year: Int, month: Int) {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        if let date = calendar.date(from: comps) {
            displayedMonth = date.dayKey
        }
    }

    /// Shows the open project's last-viewed month (falling back to the current
    /// month). The `lastViewedMonth != displayedMonth` guard on the save side
    /// keeps this from looping with the persistence onChange.
    private func restoreDisplayedMonth() {
        guard store.hasProject, let month = store.settings.lastViewedMonth else { return }
        displayedMonth = month
    }

    /// The month laid out as week rows of 7 cells each; nil = padding cell
    /// before the 1st / after the last day.
    private func weeksForDisplayedMonth() -> [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth)
        else { return [] }

        let firstDay = interval.start
        let firstWeekdayOfMonth = calendar.component(.weekday, from: firstDay)
        let leading = (firstWeekdayOfMonth - calendar.firstWeekday + 7) % 7

        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayRange.count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: firstDay))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}

// MARK: - Welcome screen

/// Shown when no project is open: create a new project or open an existing one.
struct WelcomeView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("ClipDiary")
                .font(.largeTitle.bold())
            Text("Open a project to start, or create a new one. A project is a folder that holds your clips and their trim settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button { presentNewProjectPanel(store: store) } label: {
                    Label("New Project…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { presentOpenProjectPanel(store: store) } label: {
                    Label("Open Project…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .frame(width: 360)

            if !store.recentProjects.isEmpty {
                VStack(spacing: 4) {
                    Text("Recent")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(store.recentProjects) { recent in
                        Button(recent.name) { store.openFromBookmark(recent.bookmark) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Wraps the picked 1SE file URL so it can drive `.sheet(item:)`.
struct MashSource: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Day cell

struct DayCell: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.openWindow) private var openWindow
    let day: Date
    var tagFilter: String?
    /// Keyboard selection: the calendar grid's arrow keys land here.
    var isSelected = false
    /// Context-menu "Review Sources…": open the day window focused on its source
    /// media to add clips.
    var onReview: () -> Void
    /// Clicking the cell: open the day window focused on the day's already-picked
    /// clips (also the way in to add a card and to review sources).
    var onEdit: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false
    @State private var showClipsPopover = false

    private var dayClips: [Clip] { store.clips(on: day, taggedWith: tagFilter) }
    private var hasThumbnail: Bool { thumbnail != nil }

    // A tap gesture rather than a whole-cell Button, so the badge and the
    // hover ▶ can be real buttons inside the cell (child gestures win).
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 2)
            availabilityFooter
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The thumbnail goes in the background so a scaledToFill image
        // can't stretch the cell — every cell sizes purely from its
        // content, letting the grid split height evenly.
        .background {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
        }
        .clipped()
        .overlay {
            if day.isSameDay(as: Date()) {
                Rectangle().stroke(Color.accentColor, lineWidth: 2)
            }
            if isSelected {
                Rectangle().fill(Color.accentColor.opacity(0.1))
                Rectangle().stroke(Color.accentColor, lineWidth: 3)
            } else if hovering {
                Rectangle().stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering, !dayClips.isEmpty {
                Button {
                    openWindow(value: PreviewRequest(
                        range: .custom(start: day, end: day), tagFilter: tagFilter,
                        includeBookends: false))
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Preview this day's clips, stitched like the final video")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .onHover { hovering = $0 }
        .contextMenu {
            // Both open the same day window, focused on picks vs. sources.
            Button(dayClips.isEmpty ? "Open Day…" : "Edit This Day…", action: onEdit)
            Button("Review Sources…", action: onReview)
        }
        .task(id: dayClips.first.map { store.thumbnailKey(for: $0) }) {
            if let first = dayClips.first {
                let image = await store.thumbnail(for: first)
                // The load suspends; if the day's first clip changed meanwhile
                // (e.g. the project was switched, clearing this day's clips),
                // this task was cancelled and a fresh one set the new value —
                // don't clobber it with the now-stale image.
                guard !Task.isCancelled else { return }
                thumbnail = image
            } else {
                thumbnail = nil
            }
        }
    }


    /// Day number plus a `count · length` badge for clips already picked on
    /// this day. Scrim pills (rather than a full-width gradient over the
    /// thumbnail) keep both legible on any photo.
    private var header: some View {
        HStack(alignment: .top) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.callout.bold())
                .foregroundStyle(hasThumbnail ? .white : Color.primary)
                .padding(.horizontal, hasThumbnail ? 6 : 0)
                .padding(.vertical, hasThumbnail ? 1 : 0)
                .background {
                    if hasThumbnail { Capsule().fill(.black.opacity(0.55)) }
                }
            Spacer()
            if !dayClips.isEmpty {
                let total = dayClips.reduce(0) { $0 + $1.trimmedDuration }
                Button { showClipsPopover = true } label: {
                    Text("\(dayClips.count) · \(formatDurationShort(total))")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.blue))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("See this day's clips")
                .popover(isPresented: $showClipsPopover, arrowEdge: .bottom) {
                    clipsPopover
                }
            }
        }
    }

    /// The badge popover: the day's picked clips as a filmstrip, a peek
    /// without opening the day window. Clicking a thumbnail jumps straight
    /// to editing that clip.
    private var clipsPopover: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(dayClips) { clip in
                    Button {
                        showClipsPopover = false
                        openWindow(value: ReviewRequest(day: day, startClipID: clip.id))
                    } label: {
                        TimelineClipThumb(clip: clip)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(width: min(CGFloat(dayClips.count) * 132 + 12, 566), height: 90)
        .environmentObject(store)
    }

    /// What's still available to review for this day, from the source folders:
    /// video count + combined length and photo count. Shown regardless of
    /// whether any clip has been picked.
    @ViewBuilder
    private var availabilityFooter: some View {
        let avail = store.availability(on: day)
        if !avail.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if avail.videoCount > 0 {
                    Label {
                        Text("\(avail.videoCount) · \(formatDurationShort(avail.videoDuration))")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "video.fill")
                    }
                }
                if avail.photoCount > 0 {
                    Label("\(avail.photoCount)", systemImage: "photo.fill")
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(hasThumbnail ? .white : .secondary)
            .padding(.horizontal, hasThumbnail ? 5 : 0)
            .padding(.vertical, hasThumbnail ? 2 : 0)
            .background {
                if hasThumbnail {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                }
            }
        }
    }
}

// MARK: - Timeline

/// The Timeline: the calendar's sibling browsing view (toggled in the toolbar).
/// One continuous scroll across the whole project — every day that has clips is
/// Collects each rendered timeline day row's top edge (in the scroll view's
/// coordinate space) so `TimelineBody` can tell which day is scrolled to the top.
/// Only rows currently in the lazy stack contribute, so there are no stale entries.
private struct TimelineDayTopKey: PreferenceKey {
    static let defaultValue: [Date: CGFloat] = [:]
    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// a row of that day's clip thumbnails, grouped under sticky month headers.
/// Clicking a clip opens the day editor with that clip selected.
struct TimelineBody: View {
    @EnvironmentObject var store: LibraryStore
    /// The month the calendar is on, so the timeline opens scrolled there.
    let displayedMonth: Date
    var tagFilter: String?
    /// Reports the topmost day currently scrolled into view (so the Soundtrack
    /// can open on the same stretch of time). Updated only when the day changes.
    @Binding var topVisibleDay: Date?
    /// Clicking a clip — opens the day window on it.
    var onOpenClip: (Clip) -> Void

    private var calendar: Calendar { Calendar.current }

    /// Coordinate space the day rows measure themselves against, so their
    /// scroll-relative position (used to find the topmost visible one) is
    /// independent of window insets.
    private static let scrollSpace = "timeline-scroll"

    /// One month's section in the Timeline. A `String` id keeps a section's
    /// identity from colliding with a day row's `Date` id — a month's first
    /// day's startOfDay equals the month-start instant, which otherwise makes
    /// the pinned `LazyVStack` see one id on two child views.
    private struct Month: Identifiable {
        let start: Date      // first moment of the month
        let days: [Date]     // ascending startOfDay days that have clips
        var id: String { "\(start.timeIntervalSinceReferenceDate)" }
    }

    /// Days with content (oldest first) grouped into consecutive month sections.
    private var months: [Month] {
        var result: [Month] = []
        var start: Date?
        var days: [Date] = []
        func flush() { if let start { result.append(Month(start: start, days: days)) } }
        for day in store.contentDays(taggedWith: tagFilter) {
            let month = calendar.dateInterval(of: .month, for: day)?.start ?? day
            if month == start {
                days.append(day)
            } else {
                flush()
                start = month
                days = [day]
            }
        }
        flush()
        return result
    }

    var body: some View {
        let months = self.months
        if months.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(months) { section in
                            Section {
                                ForEach(section.days, id: \.self) { day in
                                    TimelineDayRow(day: day, tagFilter: tagFilter,
                                                   onOpenClip: onOpenClip)
                                        // Each row near the pinned header reports
                                        // its top edge relative to the scroll
                                        // view; the reducer below picks the one
                                        // sitting at the top. Rows far from the
                                        // header report nothing, so the per-frame
                                        // preference merge handles a couple of
                                        // entries, not every rendered row.
                                        .background(
                                            GeometryReader { geo in
                                                let y = geo.frame(in: .named(Self.scrollSpace)).minY
                                                Color.clear.preference(
                                                    key: TimelineDayTopKey.self,
                                                    value: abs(y - Self.headerLine) < 600 ? [day: y] : [:])
                                            }
                                        )
                                }
                            } header: {
                                TimelineMonthHeader(month: section.start, tagFilter: tagFilter)
                            }
                        }
                    }
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(TimelineDayTopKey.self) { tops in
                    updateTopVisibleDay(from: tops)
                }
                .onAppear {
                    // Land near the month the calendar was on. Pinned headers can
                    // make an immediate scrollTo a no-op, so defer a tick. The
                    // scroll target is the section's id (its ForEach identity).
                    let target = targetMonthID(in: months)
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
    }

    /// ~ pinned month-header height: the y the "top" day row sits under.
    private static let headerLine: CGFloat = 44

    /// Picks the topmost visible day from the near-header rows' scroll-relative
    /// top edges and reports it up (only on change). The day sitting under the
    /// pinned month header is the one whose top is the largest value still
    /// at/above the header line; if none has reached it yet, the nearest
    /// upcoming row. An empty report (nothing near the header mid-fling) keeps
    /// the last known day.
    private func updateTopVisibleDay(from tops: [Date: CGFloat]) {
        guard !tops.isEmpty else { return }
        let reached = tops.filter { $0.value <= Self.headerLine }
        let day = (reached.max(by: { $0.value < $1.value })
                   ?? tops.min(by: { $0.value < $1.value }))?.key
        if let day, day != topVisibleDay { topVisibleDay = day }
    }

    /// The id of the month section to open on: the one containing
    /// `displayedMonth`, else the nearest earlier month with content, else the
    /// first. (`months` is non-empty here — the empty case returns early.)
    private func targetMonthID(in months: [Month]) -> String {
        let wanted = calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
        if let exact = months.first(where: { $0.start == wanted }) { return exact.id }
        return (months.last(where: { $0.start <= wanted }) ?? months[0]).id
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(tagFilter.map { "No clips tagged “\($0)”" } ?? "No clips yet")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sticky section header for a month in the Timeline: the month + year and the
/// month's picked-clip tally (count + total length).
private struct TimelineMonthHeader: View {
    @EnvironmentObject var store: LibraryStore
    let month: Date
    var tagFilter: String?

    var body: some View {
        let clips = store.clips(inMonthOf: month, taggedWith: tagFilter)
        let total = clips.reduce(0) { $0 + $1.trimmedDuration }
        HStack(spacing: 12) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title3.bold())
            Spacer()
            Text("\(clips.count) clips · \(formatDurationShort(total))")
                .foregroundStyle(.secondary)
                .font(.callout.monospacedDigit())
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// One day in the Timeline: a fixed date column (weekday + day number) and a
/// horizontally scrolling strip of that day's clip thumbnails.
private struct TimelineDayRow: View {
    @EnvironmentObject var store: LibraryStore
    let day: Date
    var tagFilter: String?
    var onOpenClip: (Clip) -> Void

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        let clips = store.clips(on: day, taggedWith: tagFilter)
        let isToday = day.isSameDay(as: Date())
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 0) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(isToday ? Color.accentColor : .primary)
                }
                .frame(width: 48)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(clips) { clip in
                            Button { onOpenClip(clip) } label: {
                                TimelineClipThumb(clip: clip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
        }
        .background(isToday ? Color.accentColor.opacity(0.06) : Color.clear)
    }
}

/// A clip thumbnail in the Timeline strip: a fixed 16:9 box with the clip's
/// kind + trimmed length, mirroring the day window's rail thumb.
private struct TimelineClipThumb: View {
    @EnvironmentObject var store: LibraryStore
    let clip: Clip

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.black.opacity(0.15)
                }
            }
            .frame(width: 124, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 2) {
                Image(systemName: clip.isCard ? "rectangle.on.rectangle.angled"
                                              : (clip.kind == .photo ? "photo" : "video"))
                Text(formatTime(clip.trimmedDuration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(hovering ? Color.accentColor : Color.black.opacity(0.12),
                        lineWidth: hovering ? 2 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .help(tooltip)
        .task(id: store.thumbnailKey(for: clip)) { image = await store.thumbnail(for: clip) }
    }

    private var tooltip: String {
        var parts: [String] = []
        if !clip.caption.isEmpty { parts.append(clip.caption) }
        if !clip.tags.isEmpty { parts.append("#" + clip.tags.joined(separator: " #")) }
        parts.append("Click to edit")
        return parts.joined(separator: "\n")
    }
}

// MARK: - Create Video (range + preview + export)

/// How the Create Video window scopes which clips go into the video. Mirrors
/// `RenderRange`'s cases as a flat, selectable value for the mode picker.
enum RenderMode: String, CaseIterable, Identifiable {
    case month, year, all, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .month: return "Month"
        case .year: return "Year"
        case .all: return "All"
        case .custom: return "Custom"
        }
    }

    init(_ range: RenderRange) {
        switch range {
        case .month: self = .month
        case .year: self = .year
        case .all: self = .all
        case .custom: self = .custom
        }
    }

    /// A range for this mode seeded from whatever the user had selected, so
    /// switching Month↔Year keeps the year and Custom starts on that month.
    func seededRange(from current: RenderRange) -> RenderRange {
        let cal = Calendar.current
        let anchor = current.anchorDate
        switch self {
        case .month: return .month(anchor)
        case .year: return .year(anchor)
        case .all: return .all
        case .custom:
            let interval = cal.dateInterval(of: .month, for: anchor)
            let start = interval?.start ?? anchor.dayKey
            let end = interval.flatMap { cal.date(byAdding: .day, value: -1, to: $0.end) } ?? start
            return .custom(start: start, end: end)
        }
    }
}

/// Single entry point for turning the project's clips into a video: pick a time
/// range, then Preview it in a window or Save it to a file. Orientation and the
/// ending fade come from Project Settings (shown read-only here). The chosen
/// range is remembered per project via `store.settings.renderRange`.
struct RenderSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var tagFilter: String?

    /// The active range, edited locally and persisted back to the project in
    /// `onChange` (below). The controls deliberately touch only this `@State`:
    /// writing to the store *during* a view update — which a Picker's setter
    /// does — is what trips SwiftUI's "Publishing changes from within view
    /// updates" warning, so the save is deferred to `onChange` instead.
    @State private var range: RenderRange

    /// Cover/Ending card selections + their fades for the **current period**,
    /// mirrored locally and persisted back to the project in `onChange` (same
    /// deferred-save reason as `range` above). Reloaded whenever `range` changes
    /// to whatever was saved for the new period (or empty when never set).
    @State private var bookends: BookendSettings
    @State private var editingBookendFade: BookendFade?

    /// Which bookend's fade sheet is open.
    private enum BookendFade: String, Identifiable { case cover, ending; var id: String { rawValue } }

    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    /// The running export, kept so the Cancel Export button can abort it.
    @State private var exportTask: Task<Void, Never>?
    @State private var showingProjectSettings = false

    /// Seeded from the project's remembered range (or the current month when it
    /// was never changed). Seeding in `init` rather than a `@State` default
    /// means `onChange` fires only on real edits, so an untouched window leaves
    /// `settings.renderRange` nil and keeps defaulting to the current month.
    init(initialRange: RenderRange, tagFilter: String?,
         initialBookends: BookendSettings = BookendSettings()) {
        _range = State(initialValue: initialRange)
        _bookends = State(initialValue: initialBookends)
        self.tagFilter = tagFilter
    }

    private var calendar: Calendar { Calendar.current }

    /// The clips the current range/tag would render, in play order — also what
    /// the bookend fades cap themselves to (first/last clip length).
    private var clips: [Clip] { store.clips(in: range, taggedWith: tagFilter) }

    private func setRange(_ new: RenderRange) {
        range = new
    }

    var body: some View {
        let clips = self.clips
        let total = clips.reduce(0) { $0 + $1.trimmedDuration }
        let videoCount = clips.filter { $0.kind == .video }.count
        let photoCount = clips.count - videoCount

        VStack(alignment: .leading, spacing: 14) {
            Text("Render Video")
                .font(.title3.bold())

            rangePicker

            Divider()

            bookendPicker

            if let tagFilter {
                Text("Only clips tagged “\(tagFilter)”.")
                    .font(.callout.bold())
            }

            Divider()

            HStack(spacing: 12) {
                if clips.isEmpty {
                    // Explains why Preview/Save are disabled — otherwise the
                    // sheet just grays out silently on an empty range.
                    Label(emptyRangeMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label(countLabel(videoCount, "video"), systemImage: "video.fill")
                    Label(countLabel(photoCount, "photo"), systemImage: "photo.fill")
                    Label(formatDurationShort(total), systemImage: "clock")
                }
                Spacer()
                // Orientation is applied from Project Settings; surface it here
                // so a wrong-orientation render doesn't come as a surprise.
                // fixedSize so wide stats (an all-clips render) push into the
                // spacer instead of wrapping this caption — a second line here
                // is what made the window quietly grow taller.
                Button {
                    showingProjectSettings = true
                } label: {
                    Text("\(store.settings.orientation.shortLabel) · Project Settings")
                        .font(.caption)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Videos render in \(store.settings.orientation.label). Click to change.")
            }
            .lineLimit(1)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            if isExporting {
                ProgressView(value: progress) {
                    Text("Saving… \(Int(progress * 100))%")
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            // Pin the buttons to the bottom of the fixed-height sheet; the
            // occasional rows above (tag note, progress, error) eat into this
            // gap instead of resizing the window.
            Spacer(minLength: 0)

            HStack {
                Button(isExporting ? "Cancel Export" : "Cancel") {
                    if isExporting {
                        exportTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                Spacer()
                Button {
                    openWindow(value: PreviewRequest(range: range, tagFilter: tagFilter))
                } label: {
                    Label("Preview", systemImage: "play.rectangle")
                }
                .disabled(isExporting || clips.isEmpty)
                Button("Save…") { chooseDestinationAndExport(clips: clips) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || clips.isEmpty)
            }
        }
        .padding(24)
        // One constant size: minHeight is sized past the tallest content, so
        // neither the mode switch nor transient rows change the window.
        .frame(width: 480)
        .frame(minHeight: 380)
        // Esc would otherwise close the sheet mid-export (the Cancel button
        // is already disabled while exporting).
        .interactiveDismissDisabled(isExporting)
        // Persist the choice as a side effect, safely outside the view update.
        .onChange(of: range) { _, newRange in
            store.updateSettings { $0.renderRange = newRange }
            // Load the bookends saved for the new period (empty when never set),
            // so the cover/ending controls track the period the user picked.
            bookends = store.settings.bookends(for: newRange)
        }
        .onChange(of: bookends) { _, new in
            store.updateSettings { $0.setBookends(new, for: range) }
        }
        .sheet(isPresented: $showingProjectSettings) {
            ProjectSettingsSheet()
        }
        .sheet(item: $editingBookendFade) { which in
            switch which {
            case .cover:
                if bookends.coverCardID != nil {
                    TransitionEditorSheet(transition: $bookends.coverTransition,
                                          maxSeconds: bookends.coverDurationSeconds)
                } else {
                    ClipFadeSheet(
                        seconds: $bookends.firstClipFadeInSeconds,
                        title: "Fade In First Clip", fadeLabel: "Fade in",
                        message: "With no cover card, fade the first clip in from black at the very start of the video.",
                        maxSeconds: clips.first?.trimmedDuration ?? 0)
                }
            case .ending:
                if bookends.endingCardID != nil {
                    TransitionEditorSheet(transition: $bookends.endingTransition,
                                          maxSeconds: bookends.endingDurationSeconds)
                } else {
                    ClipFadeSheet(
                        seconds: $bookends.lastClipFadeOutSeconds,
                        title: "Fade Out Last Clip", fadeLabel: "Fade out",
                        message: "With no ending card, fade the last clip out to black at the very end of the video.",
                        maxSeconds: clips.last?.trimmedDuration ?? 0)
                }
            }
        }
    }

    // MARK: Cover / ending cards

    /// Cover and Ending selectors, each with a fade control. With a card chosen
    /// the fade applies to the card; with **None** it instead fades the first
    /// clip in / the last clip out (the video's own opening/closing fade).
    /// Persisted per period (via `onChange`) and applied by Preview/Export.
    ///
    /// Laid out as a Grid with a fixed slot per column (label / card / duration
    /// / fade) so both rows stay aligned: controls disable instead of
    /// disappearing, and the fade button has a constant width, so nothing
    /// reflows when a selection changes.
    @ViewBuilder
    private var bookendPicker: some View {
        let hasClips = !clips.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Cover & Ending")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Cover")
                    cardMenu(selection: $bookends.coverCardID)
                    durationStepper($bookends.coverDurationSeconds,
                                    enabled: bookends.coverCardID != nil)
                    fadeButton(label: coverFadeLabel,
                               enabled: bookends.coverCardID != nil || hasClips,
                               help: bookends.coverCardID != nil
                                   ? "Fade this card in and/or out"
                                   : "Fade the first clip in from black") {
                        editingBookendFade = .cover
                    }
                }
                GridRow {
                    Text("Ending")
                    cardMenu(selection: $bookends.endingCardID)
                    durationStepper($bookends.endingDurationSeconds,
                                    enabled: bookends.endingCardID != nil)
                    fadeButton(label: endingFadeLabel,
                               enabled: bookends.endingCardID != nil || hasClips,
                               help: bookends.endingCardID != nil
                                   ? "Fade this card in and/or out"
                                   : "Fade the last clip out to black") {
                        editingBookendFade = .ending
                    }
                }
            }
            if store.cards.isEmpty {
                Text("No cards yet — design a cover or ending with the Cards button in the toolbar. With None, the fade still works on the first/last clip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fade-button label for the Cover row: the card's transition when a card is
    /// chosen, otherwise the first-clip fade-in state.
    private var coverFadeLabel: String {
        if bookends.coverCardID != nil {
            return bookends.coverTransition.isEmpty ? "Fade…" : bookends.coverTransition.summary
        }
        return bookends.firstClipFadeInSeconds > 0
            ? String(format: "Fade in %.1fs", bookends.firstClipFadeInSeconds)
            : "Fade in…"
    }

    /// Fade-button label for the Ending row (mirrors `coverFadeLabel`).
    private var endingFadeLabel: String {
        if bookends.endingCardID != nil {
            return bookends.endingTransition.isEmpty ? "Fade…" : bookends.endingTransition.summary
        }
        return bookends.lastClipFadeOutSeconds > 0
            ? String(format: "Fade out %.1fs", bookends.lastClipFadeOutSeconds)
            : "Fade out…"
    }

    private func cardMenu(selection: Binding<UUID?>) -> some View {
        Picker("", selection: selection) {
            Text("None").tag(UUID?.none)
            ForEach(store.cards) { card in
                Text(card.name).tag(UUID?.some(card.id))
            }
        }
        .labelsHidden()
        .disabled(store.cards.isEmpty)
    }

    /// Constant-width so the Cover and Ending rows stay aligned no matter what
    /// the label says ("Fade in…", "Fade out 2.0s", a transition summary, …).
    private func fadeButton(label: String, enabled: Bool, help: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: "circle.lefthalf.filled")
                .lineLimit(1)
                .frame(width: 110)
        }
        .disabled(!enabled)
        .help(help)
    }

    /// Compact "show for N.Ns" stepper for a Cover/Ending card's duration. The
    /// slot is always present so the row never reflows — it's disabled (value
    /// blanked) while that side is None.
    private func durationStepper(_ binding: Binding<Double>, enabled: Bool) -> some View {
        Stepper(value: binding, in: 0.5...30, step: 0.5) {
            Text(enabled ? String(format: "%.1fs", binding.wrappedValue) : "—")
                .monospacedDigit()
                .foregroundStyle(enabled ? .primary : .tertiary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .fixedSize()
        .disabled(!enabled)
        .help("How long this card is shown")
    }

    // MARK: Range controls

    @ViewBuilder
    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Range", selection: Binding(
                get: { RenderMode(range) },
                set: { setRange($0.seededRange(from: range)) }
            )) {
                ForEach(RenderMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // One constant-height slot for every mode's controls, so switching
            // Month/Year/All/Custom never resizes the sheet.
            ZStack(alignment: .leading) {
                switch RenderMode(range) {
                case .month:
                    let monthCounts = self.monthClipCounts
                    HStack {
                        Picker("Month", selection: monthBinding) {
                            ForEach(1...12, id: \.self) { month in
                                Text(calendar.monthSymbols[month - 1])
                                    .tag(month)
                                    .selectionDisabled(monthCounts[month - 1] == 0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        yearPicker
                    }
                case .year:
                    yearPicker
                case .all:
                    Text("Every clip in the project, oldest first.")
                        .font(.callout).foregroundStyle(.secondary)
                case .custom:
                    HStack(spacing: 12) {
                        DatePicker("From", selection: customStartBinding,
                                   displayedComponents: .date)
                        DatePicker("To", selection: customEndBinding,
                                   in: customStart..., displayedComponents: .date)
                    }
                }
            }
            .frame(height: 28, alignment: .leading)
        }
    }

    private var yearPicker: some View {
        let yearCounts = self.yearClipCounts
        return Picker("Year", selection: yearBinding) {
            ForEach(availableYears, id: \.self) { year in
                Text(verbatim: String(year))
                    .tag(year)
                    .selectionDisabled(yearCounts[year, default: 0] == 0)
            }
        }
        .labelsHidden()
        .frame(width: 90)
    }

    /// Years offered in the month/year pickers: every year that has a clip, plus
    /// the current year and the selected range's year, ascending.
    private var availableYears: [Int] {
        var years = Set(store.clips.map { calendar.component(.year, from: $0.date) })
        years.insert(calendar.component(.year, from: Date()))
        years.insert(calendar.component(.year, from: range.anchorDate))
        return years.sorted()
    }

    /// Clip counts per month of the selected year (index 0 = January),
    /// respecting the tag filter like the render does — months with nothing to
    /// render are grayed out (unselectable) in the menu.
    private var monthClipCounts: [Int] {
        let year = calendar.component(.year, from: range.anchorDate)
        var counts = [Int](repeating: 0, count: 12)
        for clip in store.clips where clip.matches(tagFilter: tagFilter) {
            let comps = calendar.dateComponents([.year, .month], from: clip.date)
            if comps.year == year, let month = comps.month { counts[month - 1] += 1 }
        }
        return counts
    }

    /// Clip counts per year, same idea as `monthClipCounts`.
    private var yearClipCounts: [Int: Int] {
        var counts: [Int: Int] = [:]
        for clip in store.clips where clip.matches(tagFilter: tagFilter) {
            counts[calendar.component(.year, from: clip.date), default: 0] += 1
        }
        return counts
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func countLabel(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Why the sheet is inert: names the empty scope ("No clips in July 2026").
    private var emptyRangeMessage: String {
        let scope: String
        switch range {
        case .all: scope = "the project"
        case .custom: scope = "this range"
        default: scope = range.label
        }
        return tagFilter == nil ? "No clips in \(scope)" : "No matching clips in \(scope)"
    }

    // MARK: Bindings into the range (writes persist via setRange)

    private var monthBinding: Binding<Int> {
        Binding(
            get: { calendar.component(.month, from: range.anchorDate) },
            set: { setRange(range.withMonth($0)) }
        )
    }

    private var yearBinding: Binding<Int> {
        Binding(
            get: { calendar.component(.year, from: range.anchorDate) },
            set: { setRange(range.withYear($0)) }
        )
    }

    private var customStart: Date {
        if case .custom(let start, _) = range { return start }
        return range.anchorDate
    }

    private var customStartBinding: Binding<Date> {
        Binding(
            get: { customStart },
            set: { newStart in
                if case .custom(_, let end) = range {
                    setRange(.custom(start: newStart, end: max(newStart, end)))
                }
            }
        )
    }

    private var customEndBinding: Binding<Date> {
        Binding(
            get: { if case .custom(_, let end) = range { return end } else { return customStart } },
            set: { newEnd in
                if case .custom(let start, _) = range {
                    setRange(.custom(start: start, end: max(start, newEnd)))
                }
            }
        )
    }

    // MARK: Export

    private func chooseDestinationAndExport(clips: [Clip]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let suffix = tagFilter.map { " – \($0)" } ?? ""
        panel.nameFieldStringValue = "ClipDiary \(range.fileNameLabel)\(suffix).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        errorMessage = nil
        progress = 0
        let renderSize = store.settings.orientation.size
        let (fadeInSeconds, fadeOutSeconds) = bookendClipFades(bookends)
        let creationDate = range.exportCreationDate(clips: clips)
        // Render the Cover/Ending cards now (on the main actor) so the export
        // task just splices the finished images on.
        let leading = bookend(for: bookends.coverCardID, transition: bookends.coverTransition,
                              seconds: bookends.coverDurationSeconds, renderSize: renderSize)
        let trailing = bookend(for: bookends.endingCardID, transition: bookends.endingTransition,
                               seconds: bookends.endingDurationSeconds, renderSize: renderSize)

        exportTask = Task {
            do {
                try await Exporter.exportMovie(
                    clips: clips, store: store, outputURL: url,
                    renderSize: renderSize,
                    fadeInSeconds: fadeInSeconds, fadeOutSeconds: fadeOutSeconds,
                    creationDate: creationDate, leading: leading, trailing: trailing
                ) { value in
                    Task { @MainActor in progress = value }
                }
                isExporting = false
                NSWorkspace.shared.activateFileViewerSelecting([url])
                dismiss()
            } catch is CancellationError {
                // User hit Cancel Export: clean up the partial file, no error.
                try? FileManager.default.removeItem(at: url)
                isExporting = false
            } catch {
                isExporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func bookend(for id: UUID?, transition: SegmentTransition,
                         seconds: Double, renderSize: CGSize) -> Bookend? {
        cardBookend(id, transition: transition, seconds: seconds, store: store, renderSize: renderSize)
    }
}

/// The render-level fades a period's bookends imply: a first-clip fade-in when
/// there's no cover card, a last-clip fade-out when there's no ending card (nil
/// = none). A chosen card supplies the opening/closing instead, so its side is
/// nil. Shared by Export and Preview so they stay in sync.
func bookendClipFades(_ b: BookendSettings) -> (fadeIn: Double?, fadeOut: Double?) {
    let fadeIn = (b.coverCardID == nil && b.firstClipFadeInSeconds > 0) ? b.firstClipFadeInSeconds : nil
    let fadeOut = (b.endingCardID == nil && b.lastClipFadeOutSeconds > 0) ? b.lastClipFadeOutSeconds : nil
    return (fadeIn, fadeOut)
}

/// Resolves a settings card id to a rendered Cover/Ending segment (nil for
/// "None" or a card that's since been deleted), shown for `seconds`. The card is
/// rendered fresh from its current document, so edits flow through. Shared by
/// Export and Preview.
@MainActor
func cardBookend(_ id: UUID?, transition: SegmentTransition, seconds: Double,
                 store: LibraryStore, renderSize: CGSize) -> Bookend? {
    guard let id, let doc = store.cards.first(where: { $0.id == id }),
          let cg = store.renderCardImage(doc, size: renderSize) else { return nil }
    return Bookend(image: cg, seconds: seconds, transition: transition)
}

// MARK: - Project settings

/// Per-project preferences: video format, ending fade, and source folders.
/// Orientation and fade here drive both Preview and Export, so neither asks
/// for a format anymore. Changes persist immediately via `store.updateSettings`.
struct ProjectSettingsSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Project Settings")
                .font(.title2.bold())

            GroupBox("Video Format") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Orientation", selection: binding(\.orientation)) {
                        ForEach(ProjectSettings.Orientation.allCases) { orientation in
                            Text(orientation.label).tag(orientation)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text("Used for both Preview and Export.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Source Folders") {
                SourceFoldersSection()
                    .padding(6)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    /// A two-way binding into the open project's settings that persists on
    /// every write (the store exposes `settings` read-only otherwise).
    private func binding<V>(_ keyPath: WritableKeyPath<ProjectSettings, V>) -> Binding<V> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in store.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }
}

// MARK: - Preview window

/// Identifies which time range (and tag filter) a preview window shows.
struct PreviewRequest: Codable, Hashable {
    var range: RenderRange
    var tagFilter: String?
    /// Whether to splice in the period's Cover/Ending cards and their fades (the
    /// first-clip fade-in / last-clip fade-out included). Off for the day
    /// editor's single-day preview — those bookend a whole video, not one day.
    var includeBookends: Bool = true
}

/// Identity that drives a preview rebuild: the render settings plus the clips
/// being rendered, so a preview refreshes when either changes.
private struct PreviewBuildKey: Equatable {
    let settings: ProjectSettings
    let clips: [Clip]
}

/// Plays the month's stitched composition in-app — same trims, ordering and
/// letterboxing as the export, without writing a file.
struct PreviewWindow: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let range: RenderRange
    var tagFilter: String?
    var includeBookends: Bool = true

    @State private var built: MonthComposition?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    /// Fraction of the composition build done (photo segments render in that
    /// pass, so big months take a while) — drives the placeholder progress bar.
    @State private var buildProgress: Double = 0
    @State private var stampText: String?
    @State private var captionText: String?
    @State private var stampObserver: Any?
    /// The date stamp's current opacity, dimmed in step with the ending fade.
    @State private var stampOpacity: Double = 1

    var body: some View {
        VStack(spacing: 12) {
            if let tagFilter {
                HStack {
                    Text("Tag: \(tagFilter)")
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.yellow.opacity(0.25)))
                    Spacer()
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if let player {
                    PlayerView(player: player)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                } else {
                    // Explicit white on the black canvas — a default-colored
                    // ProgressView is black-on-black in light mode, which made
                    // the build phase look like a blank, frozen window.
                    ProgressView(value: buildProgress) {
                        Text("Preparing preview…")
                            .foregroundStyle(.white)
                    } currentValueLabel: {
                        Text("\(Int(buildProgress * 100))%")
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                    .tint(.white)
                    .frame(maxWidth: 240)
                }
            }
            .aspectRatio(store.settings.orientation.size, contentMode: .fit)
            // Same date stamp and caption the export burns in (the export's
            // Core Animation overlay doesn't render through AVPlayer, so the
            // preview draws them itself at matching proportions).
            .overlay {
                if stampText != nil || captionText != nil {
                    GeometryReader { geo in
                        let base = min(geo.size.width, geo.size.height)
                        let fontSize = base * DateStamp.fontFraction
                        VStack(alignment: .leading, spacing: fontSize * 0.15) {
                            if let captionText {
                                let captionSize = fontSize * DateStamp.captionFontScale
                                Text(captionText)
                                    .font(.system(size: captionSize, weight: .bold))
                                    .kerning(captionSize * DateStamp.trackingFraction)
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.6), radius: 2)
                            }
                            if let stampText {
                                Text(stampText)
                                    .font(.system(size: fontSize, weight: .bold))
                                    .kerning(fontSize * DateStamp.trackingFraction)
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.6), radius: 2)
                            }
                        }
                        .padding(.leading, base * DateStamp.leftMarginFraction)
                        .padding(.bottom, base * DateStamp.bottomMarginFraction)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomLeading)
                    }
                    .opacity(stampOpacity)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: store.settings.orientation == .portrait ? 520 : 860,
               maxWidth: .infinity,
               minHeight: 480, idealHeight: 720, maxHeight: .infinity)
        // Esc closes the window, matching the app's other windows. Hidden, but
        // still wired up for the keyboard shortcut.
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .navigationTitle("Preview \(range.label)")
        // Rebuild when the settings or the clips in range change — the latter
        // so edits made (and saved) while a preview window stays open, e.g. via
        // the day editor's "Preview Day", are reflected on the next preview.
        .task(id: PreviewBuildKey(settings: store.settings,
                                  clips: store.clips(in: range, taggedWith: tagFilter))) {
            await rebuild()
        }
        .onDisappear {
            tearDownPlayer()
            built?.cleanUp()
            built = nil
        }
    }

    private func rebuild() async {
        tearDownPlayer()
        built?.cleanUp()
        built = nil
        errorMessage = nil
        buildProgress = 0

        let clips = store.clips(in: range, taggedWith: tagFilter)
        let renderSize = store.settings.orientation.size
        let bookends = store.settings.bookends(for: range)
        let (fadeIn, fadeOut) = includeBookends ? bookendClipFades(bookends) : (nil, nil)
        let leading = includeBookends ? cardBookend(bookends.coverCardID, transition: bookends.coverTransition, seconds: bookends.coverDurationSeconds, store: store, renderSize: renderSize) : nil
        let trailing = includeBookends ? cardBookend(bookends.endingCardID, transition: bookends.endingTransition, seconds: bookends.endingDurationSeconds, store: store, renderSize: renderSize) : nil
        do {
            let built = try await Exporter.buildComposition(
                clips: clips, store: store,
                renderSize: renderSize,
                fadeInSeconds: fadeIn, fadeOutSeconds: fadeOut,
                leading: leading, trailing: trailing,
                buildProgress: { value in
                    Task { @MainActor in buildProgress = value }
                }
            )
            // A settings change cancels and restarts this task; a stale build
            // finishing late must not overwrite the newer one.
            guard !Task.isCancelled else {
                built.cleanUp()
                return
            }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            let player = AVPlayer(playerItem: item)
            self.built = built
            self.player = player

            // Track which clip is playing so the date stamp and caption follow
            // along, fading the stamp in step with that clip's transition (the
            // export's Core Animation overlay does the same to the burned-in one).
            let overlays = built.dateOverlays
            func updateOverlay(at time: CMTime) {
                let o = overlays.first { $0.timeRange.containsTime(time) }
                stampText = o.flatMap { $0.text.isEmpty ? nil : $0.text }
                captionText = o.flatMap { $0.caption.isEmpty ? nil : $0.caption }
                if let o {
                    let t = (time - o.timeRange.start).seconds
                    let dur = o.timeRange.duration.seconds
                    var opacity = 1.0
                    if o.fadeInSeconds > 0, t < o.fadeInSeconds {
                        opacity = min(opacity, t / o.fadeInSeconds)
                    }
                    if o.fadeOutSeconds > 0, t > dur - o.fadeOutSeconds {
                        opacity = min(opacity, (dur - t) / o.fadeOutSeconds)
                    }
                    stampOpacity = min(max(opacity, 0), 1)
                } else {
                    stampOpacity = 1
                }
            }
            updateOverlay(at: .zero)
            stampObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { time in
                updateOverlay(at: time)
            }

            player.play()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func tearDownPlayer() {
        if let stampObserver, let player {
            player.removeTimeObserver(stampObserver)
        }
        stampObserver = nil
        stampText = nil
        captionText = nil
        stampOpacity = 1
        player?.pause()
        player = nil
    }
}
