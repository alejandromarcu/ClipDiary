import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var displayedMonth = Date().dayKey
    @State private var selectedDay: DaySelection?
    private enum ImportKind { case media, mash }
    @State private var showImporter = false
    @State private var importKind: ImportKind = .media
    @State private var mashSource: MashSource?
    @State private var showExportSheet = false
    @State private var showSourcesSheet = false
    @Environment(\.openWindow) private var openWindow
    @State private var tagFilter: String?

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
                Button { showSourcesSheet = true } label: {
                    Label("Sources", systemImage: "folder.badge.gearshape")
                }
                .help("Manage the folders scanned for this project's photos and videos")
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
                Button {
                    openWindow(value: PreviewRequest(month: displayedMonth, tagFilter: tagFilter))
                } label: {
                    Label("Preview Month", systemImage: "play.rectangle")
                }
                .disabled(store.clips(inMonthOf: displayedMonth, taggedWith: tagFilter).isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showExportSheet = true } label: {
                    Label("Export Month", systemImage: "film.stack")
                }
                .disabled(store.clips(inMonthOf: displayedMonth, taggedWith: tagFilter).isEmpty)
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
        .sheet(item: $selectedDay) { selection in
            DaySheet(day: selection.day).environmentObject(store)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(month: displayedMonth, tagFilter: tagFilter).environmentObject(store)
        }
        .sheet(isPresented: $showSourcesSheet) {
            SourceFoldersSheet().environmentObject(store)
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
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.title2.bold())
                .frame(minWidth: 220)
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
                                    onTap: { openWindow(value: ReviewRequest(day: day)) },
                                    onEdit: { selectedDay = DaySelection(day: day) }
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
            Text("Click a day to review that day's photos & videos from your source folders (↑/↓ to move, ⌘↩ to add). Right-click a day to edit its picked clips.")
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
    /// Left click: review the day's source media. Context menu: edit clips.
    var onTap: () -> Void
    var onEdit: () -> Void

    @State private var thumbnail: NSImage?

    private var dayClips: [Clip] { store.clips(on: day, taggedWith: tagFilter) }
    private var hasThumbnail: Bool { thumbnail != nil }

    var body: some View {
        Button(action: onTap) {
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
            Button("Review Sources…", action: onTap)
            Button("Edit Day's Clips…", action: onEdit)
                .disabled(dayClips.isEmpty)
        }
        .task(id: dayClips.first?.thumbnailKey) {
            if let first = dayClips.first {
                thumbnail = await store.thumbnail(for: first)
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

// MARK: - Export sheet

struct ExportSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let month: Date
    var tagFilter: String?

    @State private var orientation: Orientation = .landscape
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?

    enum Orientation: String, CaseIterable, Identifiable {
        case portrait = "Portrait (1080×1920)"
        case landscape = "Landscape (1920×1080)"
        var id: String { rawValue }
        var size: CGSize {
            self == .portrait ? CGSize(width: 1080, height: 1920)
                              : CGSize(width: 1920, height: 1080)
        }
    }

    var body: some View {
        let clips = store.clips(inMonthOf: month, taggedWith: tagFilter)
        let total = clips.reduce(0) { $0 + $1.trimmedDuration }

        VStack(alignment: .leading, spacing: 16) {
            Text("Export \(month.formatted(.dateTime.month(.wide).year()))")
                .font(.title3.bold())

            if let tagFilter {
                Text("Only clips tagged “\(tagFilter)”.")
                    .font(.callout.bold())
            }

            Text("\(clips.count) clips, total length \(formatTime(total)). Clips are stitched in date order using their trimmed in/out points.")
                .foregroundStyle(.secondary)

            Picker("Format", selection: $orientation) {
                ForEach(Orientation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .disabled(isExporting)

            if isExporting {
                ProgressView(value: progress) {
                    Text("Exporting… \(Int(progress * 100))%")
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(isExporting)
                Button("Export…") { chooseDestinationAndExport(clips: clips) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting || clips.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        // Esc would otherwise close the sheet mid-export (the Cancel button
        // is already disabled while exporting).
        .interactiveDismissDisabled(isExporting)
    }

    private func chooseDestinationAndExport(clips: [Clip]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let monthName = month.formatted(.dateTime.month(.wide).year())
        let suffix = tagFilter.map { " – \($0)" } ?? ""
        panel.nameFieldStringValue = "ClipDiary \(monthName)\(suffix).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        errorMessage = nil
        progress = 0
        let renderSize = orientation.size

        Task {
            do {
                try await Exporter.exportMovie(
                    clips: clips, store: store, outputURL: url,
                    renderSize: renderSize
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
}

// MARK: - Preview window

/// Identifies which month (and tag filter) a preview window shows.
struct PreviewRequest: Codable, Hashable {
    let month: Date
    var tagFilter: String?
}

/// Plays the month's stitched composition in-app — same trims, ordering and
/// letterboxing as the export, without writing a file.
struct PreviewWindow: View {
    @EnvironmentObject var store: LibraryStore
    let month: Date
    var tagFilter: String?

    @State private var orientation: ExportSheet.Orientation = .landscape
    @State private var built: MonthComposition?
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var stampText: String?
    @State private var captionText: String?
    @State private var stampObserver: Any?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if let tagFilter {
                    Text("Tag: \(tagFilter)")
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.yellow.opacity(0.25)))
                }
                Spacer()
                Picker("Format", selection: $orientation) {
                    ForEach(ExportSheet.Orientation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                if let player {
                    VideoPlayer(player: player)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                } else {
                    ProgressView("Preparing preview…")
                }
            }
            .aspectRatio(orientation.size, contentMode: .fit)
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
                                Text(captionText)
                                    .font(.system(size: fontSize, weight: .bold))
                                    .kerning(fontSize * DateStamp.trackingFraction)
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
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: orientation == .portrait ? 520 : 860,
               maxWidth: .infinity,
               minHeight: 480, idealHeight: 720, maxHeight: .infinity)
        .navigationTitle("Preview \(month.formatted(.dateTime.month(.wide).year()))")
        .task(id: orientation) {
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

        let clips = store.clips(inMonthOf: month, taggedWith: tagFilter)
        do {
            let built = try await Exporter.buildComposition(
                clips: clips, store: store, renderSize: orientation.size
            )
            // The orientation picker cancels and restarts this task; a stale
            // build finishing late must not overwrite the newer one.
            guard !Task.isCancelled else {
                built.cleanUp()
                return
            }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            let player = AVPlayer(playerItem: item)
            self.built = built
            self.player = player

            // Track which clip is playing so the date stamp and caption follow along.
            let overlays = built.dateOverlays
            func updateOverlay(at time: CMTime) {
                let o = overlays.first { $0.timeRange.containsTime(time) }
                stampText = o.flatMap { $0.text.isEmpty ? nil : $0.text }
                captionText = o.flatMap { $0.caption.isEmpty ? nil : $0.caption }
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
        player?.pause()
        player = nil
    }
}
