import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var displayedMonth = Date().dayKey
    private enum ImportKind { case media, mash }
    @State private var showImporter = false
    @State private var importKind: ImportKind = .media
    @State private var mashSource: MashSource?
    @State private var showRenderSheet = false
    @State private var showSourcesSheet = false
    @State private var showSettingsSheet = false
    @Environment(\.openWindow) private var openWindow
    @State private var tagFilter: String?
    @State private var showMonthPicker = false
    @State private var pickerYear = Calendar.current.component(.year, from: Date())

    private var calendar: Calendar { Calendar.current }

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
            monthHeader
            weekdayHeader
            calendarGrid
            footer
        }
        .toolbar {
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
                .help("Project settings: video format, ending fade, and source folders")
                .keyboardShortcut(",", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Media…") { importKind = .media; showImporter = true }
                    Button("Import 1SE Video…") { importKind = .mash; showImporter = true }
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
                Button { showRenderSheet = true } label: {
                    Label("Create Video…", systemImage: "film.stack")
                }
                .help("Pick a time range, then preview it or save the video")
                .disabled(store.clips(in: .all, taggedWith: tagFilter).isEmpty)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importKind == .media
                ? [.movie, .video, .mpeg4Movie, .quickTimeMovie, .image]
                : [.movie, .video, .mpeg4Movie, .quickTimeMovie],
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
            }
        }
        .sheet(item: $mashSource) { source in
            MashImportSheet(sourceURL: source.url).environmentObject(store)
        }
        .onChange(of: store.allTags) { _, tags in
            if let tagFilter,
               !tags.contains(where: { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }) {
                self.tagFilter = nil
            }
        }
        .sheet(isPresented: $showRenderSheet) {
            RenderSheet(initialRange: store.settings.renderRange ?? .month(Date()),
                        tagFilter: tagFilter,
                        initialCover: store.settings.coverCardID,
                        initialEnding: store.settings.endingCardID,
                        initialCoverTransition: store.settings.coverTransition,
                        initialEndingTransition: store.settings.endingTransition)
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

    // MARK: - Header / footer

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(by: -1) } label: { Image(systemName: "chevron.left") }
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
            Spacer()
            if let tagFilter {
                Text("Tag: \(tagFilter)")
                    .font(.callout.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.yellow.opacity(0.25)))
            }
            let avail = store.availability(inMonthOf: displayedMonth)
            if !avail.isEmpty {
                HStack(spacing: 10) {
                    if avail.videoCount > 0 {
                        Label("\(avail.videoCount) · \(formatDurationShort(avail.videoDuration))",
                              systemImage: "video.fill")
                            .monospacedDigit()
                    }
                    if avail.photoCount > 0 {
                        Label("\(avail.photoCount)", systemImage: "photo.fill")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Photos and videos available to review this month, from your source folders")
                Divider().frame(height: 16)
            }

            let monthClips = store.clips(inMonthOf: displayedMonth, taggedWith: tagFilter)
            let total = monthClips.reduce(0) { $0 + $1.trimmedDuration }
            Text("\(monthClips.count) clips · \(formatTime(total))")
                .foregroundStyle(.secondary)
                .font(.callout.monospacedDigit())
        }
        .padding()
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
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
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
                                    onReview: { openWindow(value: ReviewRequest(day: day)) },
                                    onEdit: { openWindow(value: DayEditRequest(day: day)) }
                                )
                                .environmentObject(store)
                            } else {
                                Color(nsColor: .controlBackgroundColor).opacity(0.35)
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

    private var footer: some View {
        HStack {
            Image(systemName: "info.circle")
            Text("Tap a day's + to review that day's photos & videos from your source folders (↑/↓ to move, ⌘↩ to add). Click anywhere else on a day to edit its picked clips.")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
    }

    // MARK: - Helpers

    private func shiftMonth(by delta: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = newMonth
        }
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
    let day: Date
    var tagFilter: String?
    /// The + circle: review the day's source media and add clips.
    var onReview: () -> Void
    /// Clicking anywhere else on the cell: open the day's clip editor (also the
    /// way in to add a card, so empty days still have a destination).
    var onEdit: () -> Void

    @State private var thumbnail: NSImage?
    // Hover is tracked separately for the cell and the + button, then OR'd:
    // moving onto the button makes the cell's tracking area report "exited"
    // (the button has its own pointer tracking), so a single flag would flicker
    // off mid-hover. With two flags, the button stays revealed as long as the
    // pointer is over either region.
    @State private var hoveringCell = false
    @State private var hoveringButton = false
    private var isHovering: Bool { hoveringCell || hoveringButton }

    private var dayClips: [Clip] { store.clips(on: day, taggedWith: tagFilter) }
    private var hasThumbnail: Bool { thumbnail != nil }

    var body: some View {
        Button(action: onEdit) {
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
                            .overlay(
                                LinearGradient(
                                    colors: [.black.opacity(0.6), .clear, .black.opacity(0.55)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                }
            }
            .clipped()
            .overlay {
                if day.isSameDay(as: Date()) {
                    Rectangle().stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringCell = $0 }
        // A dedicated review button so the whole-cell tap can mean "edit". It
        // sits on top of the edit button and consumes clicks in its own circle.
        // Revealed on hover to keep a full month of cells from looking busy
        // (its corner stays the review target even faded out — the pointer is
        // already over the cell, so the + is showing by the time it's clicked).
        .overlay(alignment: .bottomTrailing) {
            reviewButton
                .opacity(isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .contextMenu {
            // Always reachable — the day editor is also where a card is added,
            // so an empty day still needs a way in.
            Button(dayClips.isEmpty ? "Edit Day…" : "Edit Day's Clips…", action: onEdit)
            Button("Review Sources…", action: onReview)
        }
        .task(id: dayClips.first?.thumbnailKey) {
            if let first = dayClips.first {
                thumbnail = await store.thumbnail(for: first)
            } else {
                thumbnail = nil
            }
        }
    }

    /// Bottom-right + circle that opens the review window for this day.
    private var reviewButton: some View {
        Button(action: onReview) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hoveringButton = $0 }
        .padding(6)
        .help("Review this day's photos & videos and add clips")
    }

    /// Day number plus a badge for clips already picked on this day.
    private var header: some View {
        HStack(alignment: .top) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.callout.bold())
                .foregroundStyle(hasThumbnail ? .white : Color.primary)
            Spacer()
            if dayClips.count > 1 {
                Text("\(dayClips.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.blue))
                    .foregroundStyle(.white)
            } else if let first = dayClips.first {
                Text(formatTime(first.trimmedDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(hasThumbnail ? .white.opacity(0.9) : .secondary)
            }
        }
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
            .foregroundStyle(hasThumbnail ? .white.opacity(0.95) : .secondary)
        }
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

    /// Cover/Ending card selections + their fades, mirrored locally and
    /// persisted back to the project in `onChange` (same deferred-save reason as
    /// `range` above).
    @State private var coverCardID: UUID?
    @State private var endingCardID: UUID?
    @State private var coverTransition = SegmentTransition()
    @State private var endingTransition = SegmentTransition()
    @State private var editingBookendFade: BookendFade?

    /// Which bookend's fade sheet is open.
    private enum BookendFade: String, Identifiable { case cover, ending; var id: String { rawValue } }

    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?

    /// Seeded from the project's remembered range (or the current month when it
    /// was never changed). Seeding in `init` rather than a `@State` default
    /// means `onChange` fires only on real edits, so an untouched window leaves
    /// `settings.renderRange` nil and keeps defaulting to the current month.
    init(initialRange: RenderRange, tagFilter: String?,
         initialCover: UUID? = nil, initialEnding: UUID? = nil,
         initialCoverTransition: SegmentTransition = SegmentTransition(),
         initialEndingTransition: SegmentTransition = SegmentTransition()) {
        _range = State(initialValue: initialRange)
        _coverCardID = State(initialValue: initialCover)
        _endingCardID = State(initialValue: initialEnding)
        _coverTransition = State(initialValue: initialCoverTransition)
        _endingTransition = State(initialValue: initialEndingTransition)
        self.tagFilter = tagFilter
    }

    private var calendar: Calendar { Calendar.current }

    private func setRange(_ new: RenderRange) {
        range = new
    }

    var body: some View {
        let clips = store.clips(in: range, taggedWith: tagFilter)
        let total = clips.reduce(0) { $0 + $1.trimmedDuration }
        let videoCount = clips.filter { $0.kind == .video }.count
        let photoCount = clips.count - videoCount

        VStack(alignment: .leading, spacing: 16) {
            Text("Create Video")
                .font(.title3.bold())

            rangePicker

            bookendPicker

            if let tagFilter {
                Text("Only clips tagged “\(tagFilter)”.")
                    .font(.callout.bold())
            }

            HStack(spacing: 16) {
                Label("\(videoCount)", systemImage: "video.fill")
                Label("\(photoCount)", systemImage: "photo.fill")
                Label(formatDurationShort(total), systemImage: "clock")
            }
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

            HStack {
                Button("Cancel") { dismiss() }.disabled(isExporting)
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
        .frame(width: 460)
        // Esc would otherwise close the sheet mid-export (the Cancel button
        // is already disabled while exporting).
        .interactiveDismissDisabled(isExporting)
        // Persist the choice as a side effect, safely outside the view update.
        .onChange(of: range) { _, newRange in
            store.updateSettings { $0.renderRange = newRange }
        }
        .onChange(of: coverCardID) { _, new in
            store.updateSettings { $0.coverCardID = new }
        }
        .onChange(of: endingCardID) { _, new in
            store.updateSettings { $0.endingCardID = new }
        }
        .onChange(of: coverTransition) { _, new in
            store.updateSettings { $0.coverTransition = new }
        }
        .onChange(of: endingTransition) { _, new in
            store.updateSettings { $0.endingTransition = new }
        }
        .sheet(item: $editingBookendFade) { which in
            let isCover = which == .cover
            TransitionEditorSheet(
                transition: isCover ? $coverTransition : $endingTransition,
                maxSeconds: cardDuration(isCover ? coverCardID : endingCardID)
            )
        }
    }

    // MARK: Cover / ending cards

    /// Cover and Ending card selectors, each with a fade control. Persisted per
    /// project (via `onChange`) and rendered onto the start/end of Preview/Export.
    @ViewBuilder
    private var bookendPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cover")
                    .frame(width: 60, alignment: .leading)
                cardMenu(selection: $coverCardID)
                fadeButton(coverTransition, enabled: coverCardID != nil) { editingBookendFade = .cover }
            }
            HStack {
                Text("Ending")
                    .frame(width: 60, alignment: .leading)
                cardMenu(selection: $endingCardID)
                fadeButton(endingTransition, enabled: endingCardID != nil) { editingBookendFade = .ending }
            }
            if store.cards.isEmpty {
                Text("No cards yet — design a cover or ending with the Cards button in the toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    private func fadeButton(_ transition: SegmentTransition, enabled: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(transition.isEmpty ? "Fade…" : transition.summary,
                  systemImage: "circle.lefthalf.filled")
        }
        .disabled(!enabled)
        .help("Fade this card in and/or out")
        .fixedSize()
    }

    /// The chosen card's display length, used to cap its fades (default if none).
    private func cardDuration(_ id: UUID?) -> Double {
        id.flatMap { cid in store.cards.first(where: { $0.id == cid })?.displaySeconds }
            ?? Card.defaultDisplaySeconds
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

            switch RenderMode(range) {
            case .month:
                HStack {
                    Picker("Month", selection: monthBinding) {
                        ForEach(1...12, id: \.self) { month in
                            Text(calendar.monthSymbols[month - 1]).tag(month)
                        }
                    }
                    .labelsHidden()
                    Picker("Year", selection: yearBinding) {
                        ForEach(availableYears, id: \.self) { year in
                            Text(verbatim: String(year)).tag(year)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            case .year:
                Picker("Year", selection: yearBinding) {
                    ForEach(availableYears, id: \.self) { year in
                        Text(verbatim: String(year)).tag(year)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
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
    }

    /// Years offered in the month/year pickers: every year that has a clip, plus
    /// the current year and the selected range's year, ascending.
    private var availableYears: [Int] {
        var years = Set(store.clips.map { calendar.component(.year, from: $0.date) })
        years.insert(calendar.component(.year, from: Date()))
        years.insert(calendar.component(.year, from: range.anchorDate))
        return years.sorted()
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
        let fadeOutSeconds = store.settings.effectiveFadeOutSeconds
        let creationDate = range.exportCreationDate(clips: clips)
        // Render the Cover/Ending cards now (on the main actor) so the export
        // task just splices the finished images on.
        let leading = bookend(for: coverCardID, transition: coverTransition, renderSize: renderSize)
        let trailing = bookend(for: endingCardID, transition: endingTransition, renderSize: renderSize)

        Task {
            do {
                try await Exporter.exportMovie(
                    clips: clips, store: store, outputURL: url,
                    renderSize: renderSize, fadeOutSeconds: fadeOutSeconds,
                    creationDate: creationDate, leading: leading, trailing: trailing
                ) { value in
                    Task { @MainActor in progress = value }
                }
                isExporting = false
                NSWorkspace.shared.activateFileViewerSelecting([url])
                dismiss()
            } catch {
                isExporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func bookend(for id: UUID?, transition: SegmentTransition, renderSize: CGSize) -> Bookend? {
        cardBookend(id, transition: transition, store: store, renderSize: renderSize)
    }
}

/// Resolves a settings card id to a rendered Cover/Ending segment (nil for
/// "None" or a card that's since been deleted). Shared by Export and Preview.
@MainActor
func cardBookend(_ id: UUID?, transition: SegmentTransition,
                 store: LibraryStore, renderSize: CGSize) -> Bookend? {
    guard let id, let doc = store.cards.first(where: { $0.id == id }),
          let cg = store.renderCardImage(doc, size: renderSize) else { return nil }
    return Bookend(image: cg, seconds: doc.displaySeconds, transition: transition)
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

            GroupBox("Ending") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Fade out the last clip", isOn: binding(\.fadeOutLastClip))
                    HStack(spacing: 6) {
                        Text("Fade duration")
                        Spacer()
                        TextField("Fade duration", value: fadeSecondsBinding,
                                  format: .number.precision(.fractionLength(1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 44)
                        Text("s")
                        Stepper("Fade duration", value: fadeSecondsBinding,
                                in: Self.fadeSecondsRange, step: 0.1)
                            .labelsHidden()
                    }
                    .disabled(!store.settings.fadeOutLastClip)
                    .foregroundStyle(store.settings.fadeOutLastClip ? .primary : .secondary)
                    Text("Fades the video, audio and date stamp to black at the very end of the month.")
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

    private static let fadeSecondsRange: ClosedRange<Double> = 0.3...5.0

    /// Fade-duration binding that clamps to the valid range — the `TextField`
    /// lets the user type any number, so the bounds can't live on the `Stepper`
    /// alone (those only limit its arrows).
    private var fadeSecondsBinding: Binding<Double> {
        Binding(
            get: { store.settings.fadeOutSeconds },
            set: { newValue in
                let clamped = min(max(newValue, Self.fadeSecondsRange.lowerBound),
                                  Self.fadeSecondsRange.upperBound)
                store.updateSettings { $0.fadeOutSeconds = clamped }
            }
        )
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
    /// The ending fade-to-black is meant for the very last clip of a full
    /// render, so the day editor's single-day preview opts out of it.
    var includeEndingFade: Bool = true
    /// Whether to splice in the project's Cover/Ending cards. Off for the day
    /// editor's single-day preview (those bookend a whole video, not one day).
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
    var includeEndingFade: Bool = true
    var includeBookends: Bool = true

    @State private var built: MonthComposition?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
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
                    ProgressView("Preparing preview…")
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

        let clips = store.clips(in: range, taggedWith: tagFilter)
        let renderSize = store.settings.orientation.size
        let leading = includeBookends ? cardBookend(store.settings.coverCardID, transition: store.settings.coverTransition, store: store, renderSize: renderSize) : nil
        let trailing = includeBookends ? cardBookend(store.settings.endingCardID, transition: store.settings.endingTransition, store: store, renderSize: renderSize) : nil
        do {
            let built = try await Exporter.buildComposition(
                clips: clips, store: store,
                renderSize: renderSize,
                fadeOutSeconds: includeEndingFade ? store.settings.effectiveFadeOutSeconds : nil,
                leading: leading, trailing: trailing
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
