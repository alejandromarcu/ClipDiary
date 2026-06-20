import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var displayedMonth = Date().dayKey
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
    @State private var showMonthPicker = false
    @State private var pickerYear = Calendar.current.component(.year, from: Date())

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
            monthHeader
            weekdayHeader
            calendarGrid
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
                                    onReview: { openWindow(value: ReviewRequest(day: day, focusSources: true)) },
                                    onEdit: { openWindow(value: ReviewRequest(day: day)) }
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
    /// Context-menu "Review Sources…": open the day window focused on its source
    /// media to add clips.
    var onReview: () -> Void
    /// Clicking the cell: open the day window focused on the day's already-picked
    /// clips (also the way in to add a card and to review sources).
    var onEdit: () -> Void

    @State private var thumbnail: NSImage?

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
            // Load the bookends saved for the new period (empty when never set),
            // so the cover/ending controls track the period the user picked.
            bookends = store.settings.bookends(for: newRange)
        }
        .onChange(of: bookends) { _, new in
            store.updateSettings { $0.setBookends(new, for: range) }
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
    @ViewBuilder
    private var bookendPicker: some View {
        let hasClips = !clips.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cover")
                    .frame(width: 60, alignment: .leading)
                cardMenu(selection: $bookends.coverCardID)
                if bookends.coverCardID != nil {
                    durationStepper($bookends.coverDurationSeconds)
                }
                fadeButton(label: coverFadeLabel,
                           enabled: bookends.coverCardID != nil || hasClips,
                           help: bookends.coverCardID != nil
                               ? "Fade this card in and/or out"
                               : "Fade the first clip in from black") {
                    editingBookendFade = .cover
                }
            }
            HStack {
                Text("Ending")
                    .frame(width: 60, alignment: .leading)
                cardMenu(selection: $bookends.endingCardID)
                if bookends.endingCardID != nil {
                    durationStepper($bookends.endingDurationSeconds)
                }
                fadeButton(label: endingFadeLabel,
                           enabled: bookends.endingCardID != nil || hasClips,
                           help: bookends.endingCardID != nil
                               ? "Fade this card in and/or out"
                               : "Fade the last clip out to black") {
                    editingBookendFade = .ending
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

    private func fadeButton(label: String, enabled: Bool, help: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: "circle.lefthalf.filled")
        }
        .disabled(!enabled)
        .help(help)
        .fixedSize()
    }

    /// Compact "show for N.Ns" stepper for a Cover/Ending card's duration,
    /// shown only when that side has a card selected.
    private func durationStepper(_ binding: Binding<Double>) -> some View {
        Stepper(value: binding, in: 0.5...30, step: 0.5) {
            Text(String(format: "%.1fs", binding.wrappedValue))
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
        }
        .fixedSize()
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
        let (fadeInSeconds, fadeOutSeconds) = bookendClipFades(bookends)
        let creationDate = range.exportCreationDate(clips: clips)
        // Render the Cover/Ending cards now (on the main actor) so the export
        // task just splices the finished images on.
        let leading = bookend(for: bookends.coverCardID, transition: bookends.coverTransition,
                              seconds: bookends.coverDurationSeconds, renderSize: renderSize)
        let trailing = bookend(for: bookends.endingCardID, transition: bookends.endingTransition,
                               seconds: bookends.endingDurationSeconds, renderSize: renderSize)

        Task {
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
        let bookends = store.settings.bookends(for: range)
        let (fadeIn, fadeOut) = includeBookends ? bookendClipFades(bookends) : (nil, nil)
        let leading = includeBookends ? cardBookend(bookends.coverCardID, transition: bookends.coverTransition, seconds: bookends.coverDurationSeconds, store: store, renderSize: renderSize) : nil
        let trailing = includeBookends ? cardBookend(bookends.endingCardID, transition: bookends.endingTransition, seconds: bookends.endingDurationSeconds, store: store, renderSize: renderSize) : nil
        do {
            let built = try await Exporter.buildComposition(
                clips: clips, store: store,
                renderSize: renderSize,
                fadeInSeconds: fadeIn, fadeOutSeconds: fadeOut,
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
