import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore

    @State private var displayedMonth = Date().dayKey
    @State private var selectedDay: Date?
    private enum ImportKind { case media, mash }
    @State private var showImporter = false
    @State private var importKind: ImportKind = .media
    @State private var mashSource: MashSource?
    @State private var showExportSheet = false
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
        .sheet(item: $selectedDay) { day in
            DaySheet(day: day).environmentObject(store)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(month: displayedMonth, tagFilter: tagFilter).environmentObject(store)
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

    private var calendarGrid: some View {
        let days = daysForDisplayedMonth()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        DayCell(day: day, tagFilter: tagFilter) { selectedDay = day }
                            .environmentObject(store)
                    } else {
                        Color.clear.frame(height: 86)
                    }
                }
            }
            .padding()
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "info.circle")
            Text("Drag the yellow handles in a day's editor to cut the beginning and end of a clip. Clips can be any length.")
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

    /// All cells for the month grid; nil = padding cell before the 1st / after the last day.
    private func daysForDisplayedMonth() -> [Date?] {
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
        return cells
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

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}

// MARK: - Day cell

struct DayCell: View {
    @EnvironmentObject var store: LibraryStore
    let day: Date
    var tagFilter: String?
    var onTap: () -> Void

    @State private var thumbnail: NSImage?

    private var dayClips: [Clip] { store.clips(on: day, taggedWith: tagFilter) }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            LinearGradient(
                                colors: [.black.opacity(0.55), .clear],
                                startPoint: .top, endPoint: .center
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        )
                }

                HStack {
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.callout.bold())
                        .foregroundStyle(thumbnail == nil ? Color.primary : .white)
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
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(6)

                if day.isSameDay(as: Date()) {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .frame(height: 86)
        }
        .buttonStyle(.plain)
        .task(id: dayClips.first?.id.uuidString ?? "" + "\(dayClips.first?.inSeconds ?? 0)") {
            if let first = dayClips.first {
                thumbnail = await store.thumbnail(for: first)
            } else {
                thumbnail = nil
            }
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
            // Same date stamp the export burns in (the export's Core
            // Animation overlay doesn't render through AVPlayer, so the
            // preview draws it itself at matching proportions).
            .overlay {
                if let stampText {
                    GeometryReader { geo in
                        let base = min(geo.size.width, geo.size.height)
                        let fontSize = base * DateStamp.fontFraction
                        Text(stampText)
                            .font(.system(size: fontSize, weight: .bold))
                            .kerning(fontSize * DateStamp.trackingFraction)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
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
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            let player = AVPlayer(playerItem: item)
            self.built = built
            self.player = player

            // Track which clip is playing so the date stamp follows along.
            let overlays = built.dateOverlays
            stampText = overlays.first { $0.timeRange.containsTime(.zero) }?.text
            stampObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { time in
                stampText = overlays.first { $0.timeRange.containsTime(time) }?.text
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
        player?.pause()
        player = nil
    }
}
