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
    @State private var showSettingsSheet = false
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

    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?

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

            HStack(spacing: 6) {
                Text("Format:").foregroundStyle(.secondary)
                Text(store.settings.orientation.label)
                if store.settings.fadeOutLastClip {
                    Text("· fades out").foregroundStyle(.secondary)
                }
                Spacer()
                Text("Change in Project Settings (⌘,)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

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
        let renderSize = store.settings.orientation.size
        let fadeOutSeconds = store.settings.effectiveFadeOutSeconds

        Task {
            do {
                try await Exporter.exportMovie(
                    clips: clips, store: store, outputURL: url,
                    renderSize: renderSize, fadeOutSeconds: fadeOutSeconds
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
            HStack {
                if let tagFilter {
                    Text("Tag: \(tagFilter)")
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.yellow.opacity(0.25)))
                }
                Spacer()
                Text(store.settings.orientation.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .navigationTitle("Preview \(month.formatted(.dateTime.month(.wide).year()))")
        .task(id: store.settings) {
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
                clips: clips, store: store,
                renderSize: store.settings.orientation.size,
                fadeOutSeconds: store.settings.effectiveFadeOutSeconds
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
            // along, and fade the stamp out over the ending fade (the export's
            // Core Animation overlay does the same to the burned-in stamp).
            let overlays = built.dateOverlays
            let fade = built.fadeRange
            func updateOverlay(at time: CMTime) {
                let o = overlays.first { $0.timeRange.containsTime(time) }
                stampText = o.flatMap { $0.text.isEmpty ? nil : $0.text }
                captionText = o.flatMap { $0.caption.isEmpty ? nil : $0.caption }
                if let fade, time >= fade.start {
                    let remaining = (fade.end - time).seconds / fade.duration.seconds
                    stampOpacity = min(max(remaining, 0), 1)
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
