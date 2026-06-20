import Foundation
import AVFoundation
import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Owns the clip library for the **currently open project**: a user-chosen
/// directory holding `clips.json` (metadata) + a `Clips/` subfolder of copied
/// media files. The last-used project reopens across launches via a
/// security-scoped bookmark (the sandbox only grants persistent folder access
/// that way). With no project open the app shows its welcome screen.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var clips: [Clip] = [] {
        didSet { clipsByDayCache = nil }
    }
    @Published var lastError: String?

    /// The open project's root directory, or nil when none is open.
    /// `clipsDir`/`metadataURL` are valid exactly when this is non-nil, so the
    /// file-accessing methods below are only reached with a project open.
    @Published private(set) var currentProjectURL: URL?

    /// The project's source folders (review-window inventory) and the media
    /// found inside them, sorted by capture time.
    @Published private(set) var sourceFolders: [SourceFolder] = []
    @Published private(set) var sourceItems: [SourceItem] = [] {
        didSet { sourceItemsByDayCache = nil }
    }
    @Published private(set) var isScanningSources = false

    /// The open project's render preferences (orientation, ending fade).
    /// Mutated only through `updateSettings`, which also persists.
    @Published private(set) var settings = ProjectSettings()

    /// The project's designed title cards (gallery), sorted by name. Each lives
    /// in its own folder under `Cards/` — see `Cards.swift`.
    @Published private(set) var cards: [CardDocument] = []

    private var clipsDir: URL!
    private var metadataURL: URL!
    private var sourcesURL: URL!
    private var settingsURL: URL!
    private var cardsDir: URL!
    /// The security-scoped URL we currently hold access to (released before we
    /// switch to another project). nil for open/save-panel URLs, which the
    /// sandbox keeps accessible for the whole process without start/stop.
    private var accessingScopedURL: URL?
    /// Source folders we hold security-scoped access to (resolved from the
    /// project's stored bookmarks; released on project switch).
    private var accessingSourceURLs: [URL] = []
    private var scanTask: Task<Void, Never>?
    private let thumbnailCache = NSCache<NSUUID, NSImage>()
    /// Thumbnails for not-yet-picked source items (keyed by file path), shown in
    /// the day window's source rail. Separate from `thumbnailCache` because
    /// source items are keyed by path, not by a clip's UUID.
    private let sourceThumbnailCache = NSCache<NSString, NSImage>()
    /// Clips and source items grouped by calendar day (`startOfDay` key), built
    /// lazily and dropped whenever `clips`/`sourceItems` change. The calendar
    /// draws ~40 day cells, each querying its day's clips and availability
    /// several times per render; a full O(count) scan per query (with costly
    /// `Calendar.isDate(inSameDayAs:)` comparisons) made month navigation crawl
    /// once a library held thousands of clips.
    private var clipsByDayCache: [Date: [Clip]]?
    private var sourceItemsByDayCache: [Date: [SourceItem]]?

    var currentProjectName: String? { currentProjectURL?.lastPathComponent }
    var hasProject: Bool { currentProjectURL != nil }

    init() {
        restoreLastProject()
    }

    func fileURL(for clip: Clip) -> URL {
        clipsDir.appendingPathComponent(clip.fileName)
    }

    // MARK: - Persistence

    /// Reads and decodes a project's clip list. Throws when the file can't
    /// be read or decoded — opening such a project as empty would overwrite
    /// the real data with `[]` on the next save.
    private static func loadClips(from url: URL) throws -> [Clip] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Clip].self, from: data)
    }

    private func save() {
        guard let metadataURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(clips)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            lastError = "Could not save library: \(error.localizedDescription)"
        }
    }

    /// Reads a project's `settings.json`, falling back to defaults when it's
    /// missing or unreadable (older projects never wrote one).
    private static func loadSettings(from url: URL) -> ProjectSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProjectSettings.self, from: data)
        else { return ProjectSettings() }
        return decoded
    }

    private func saveSettings() {
        guard let settingsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            lastError = "Could not save project settings: \(error.localizedDescription)"
        }
    }

    /// Mutates the open project's settings and persists the result. The only
    /// supported way to change `settings` (which is otherwise read-only).
    func updateSettings(_ mutate: (inout ProjectSettings) -> Void) {
        mutate(&settings)
        saveSettings()
    }

    // MARK: - Projects

    /// Creates a new project directory at `url` (its `Clips/` subfolder + an
    /// empty `clips.json`), then opens it. `url` comes from a save panel, so
    /// the sandbox grants access for this launch.
    func createProject(at url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent("Clips", isDirectory: true),
                withIntermediateDirectories: true
            )
            let metaURL = url.appendingPathComponent("clips.json")
            if !FileManager.default.fileExists(atPath: metaURL.path) {
                try Data("[]".utf8).write(to: metaURL, options: .atomic)
            }
        } catch {
            lastError = "Could not create project: \(error.localizedDescription)"
            return
        }
        openProject(at: url)
    }

    /// Opens an existing project directory (e.g. picked in the open panel).
    func openProject(at url: URL) {
        activateProject(at: url, takeScope: false)
    }

    /// Restores the last-used project from its saved bookmark, if any.
    /// Pruning of dead bookmarks happens inside `openFromBookmark`.
    func restoreLastProject() {
        guard let data = UserDefaults.standard.data(forKey: Keys.lastBookmark) else { return }
        openFromBookmark(data)
    }

    /// Resolves a stored bookmark, takes security-scoped access, and opens the
    /// project. Returns false if it can't be opened; the bookmark is pruned
    /// when the folder is gone or no longer a project, but kept when only its
    /// clip list won't decode (the user can fix the file and retry).
    @discardableResult
    func openFromBookmark(_ data: Data) -> Bool {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else {
            forgetBookmark(data)
            return false
        }
        switch activateProject(at: url, takeScope: true) {
        case .opened:
            return true
        case .notAProject:
            forgetBookmark(data)
            return false
        case .unreadableLibrary:
            return false
        }
    }

    private enum ActivationResult { case opened, notAProject, unreadableLibrary }

    /// Switches to `url`: loads its clips, releases the previous scope,
    /// optionally keeps security-scoped access, and records it as last-used +
    /// most-recent. Fails without switching (the current project stays open)
    /// if `url` isn't a project or its clip list won't decode — opening a
    /// project whose clips.json exists but can't be read would silently
    /// overwrite the real data with an empty library on the next save.
    @discardableResult
    private func activateProject(at url: URL, takeScope: Bool) -> ActivationResult {
        let metaURL = url.appendingPathComponent("clips.json")
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            if takeScope { url.stopAccessingSecurityScopedResource() }
            lastError = "“\(url.lastPathComponent)” isn’t a ClipDiary project (no clips.json). Use New Project to create one."
            return .notAProject
        }
        let loadedClips: [Clip]
        do {
            loadedClips = try Self.loadClips(from: metaURL)
        } catch {
            if takeScope { url.stopAccessingSecurityScopedResource() }
            lastError = "Could not read the clip list of “\(url.lastPathComponent)”: \(error.localizedDescription)\n\nThe project was not opened and its clips.json is untouched — restore or fix the file and try again."
            return .unreadableLibrary
        }
        releaseCurrentScope()
        accessingScopedURL = takeScope ? url : nil

        currentProjectURL = url
        clipsDir = url.appendingPathComponent("Clips", isDirectory: true)
        metadataURL = metaURL
        sourcesURL = url.appendingPathComponent("sources.json")
        settingsURL = url.appendingPathComponent("settings.json")
        cardsDir = url.appendingPathComponent("Cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        thumbnailCache.removeAllObjects()
        sourceThumbnailCache.removeAllObjects()
        clips = loadedClips
        settings = Self.loadSettings(from: settingsURL)
        cards = Self.loadCards(from: cardsDir)
        loadSources()
        rememberProject(url)
        return .opened
    }

    private func releaseCurrentScope() {
        accessingScopedURL?.stopAccessingSecurityScopedResource()
        accessingScopedURL = nil
        scanTask?.cancel()
        accessingSourceURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessingSourceURLs = []
        sourceFolders = []
        sourceItems = []
        isScanningSources = false
        cards = []
    }

    // MARK: - Recent projects (security-scoped bookmarks)

    private enum Keys {
        static let lastBookmark = "lastProjectBookmark"
        static let recentBookmarks = "recentProjectBookmarks"
    }
    private static let maxRecents = 10

    /// Recently opened projects, newest first, for the Open Recent menu.
    /// Resolving for display doesn't take access — only opening one does.
    var recentProjects: [RecentProject] {
        storedRecentBookmarks().compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale)
            else { return nil }
            return RecentProject(url: url, bookmark: data)
        }
    }

    func clearRecentProjects() {
        UserDefaults.standard.removeObject(forKey: Keys.recentBookmarks)
        objectWillChange.send()
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope,
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func storedRecentBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: Keys.recentBookmarks) as? [Data] ?? []
    }

    /// Persists `url` as the last-used project and bumps it to the front of the
    /// recents list (also refreshing its bookmark, e.g. when it went stale).
    private func rememberProject(_ url: URL) {
        guard let bookmark = makeBookmark(for: url) else { return }
        let defaults = UserDefaults.standard
        defaults.set(bookmark, forKey: Keys.lastBookmark)

        var recents = storedRecentBookmarks().filter { data in
            var stale = false
            let existing = try? URL(resolvingBookmarkData: data,
                                    options: .withSecurityScope,
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
            return existing?.standardizedFileURL != url.standardizedFileURL
        }
        recents.insert(bookmark, at: 0)
        defaults.set(Array(recents.prefix(Self.maxRecents)), forKey: Keys.recentBookmarks)
    }

    private func forgetBookmark(_ data: Data) {
        let defaults = UserDefaults.standard
        if defaults.data(forKey: Keys.lastBookmark) == data {
            defaults.removeObject(forKey: Keys.lastBookmark)
        }
        defaults.set(storedRecentBookmarks().filter { $0 != data }, forKey: Keys.recentBookmarks)
    }

    // MARK: - Source folders

    /// Loads `sources.json`, takes security-scoped access to each folder, and
    /// kicks off a scan. Folders whose bookmarks no longer resolve are
    /// dropped from view but kept on disk (the folder may reappear).
    private func loadSources() {
        var folders: [SourceFolder] = []
        if let data = try? Data(contentsOf: sourcesURL),
           let records = try? JSONDecoder().decode([SourceFolderRecord].self, from: data) {
            for record in records {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: record.bookmark,
                                         options: .withSecurityScope,
                                         relativeTo: nil,
                                         bookmarkDataIsStale: &stale)
                else { continue }
                if url.startAccessingSecurityScopedResource() {
                    accessingSourceURLs.append(url)
                } else {
                    lastError = "Could not regain access to source folder “\(url.lastPathComponent)” — its files won't appear in review. Try removing and re-adding it in Sources."
                }
                folders.append(SourceFolder(url: url, bookmark: record.bookmark))
            }
        }
        sourceFolders = folders
        rescanSources()
    }

    private func saveSources() {
        let records = sourceFolders.map {
            SourceFolderRecord(bookmark: $0.bookmark, path: $0.url.path)
        }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: sourcesURL, options: .atomic)
        } catch {
            lastError = "Could not save source folders: \(error.localizedDescription)"
        }
    }

    /// Adds a folder picked in an open panel (already accessible this launch;
    /// the bookmark regains access on later launches).
    func addSourceFolder(_ url: URL) {
        guard hasProject else { return }
        guard !sourceFolders.contains(where: { $0.id == url.standardizedFileURL.path }) else { return }
        guard let bookmark = makeBookmark(for: url) else {
            lastError = "Could not bookmark “\(url.lastPathComponent)” for future launches."
            return
        }
        sourceFolders.append(SourceFolder(url: url, bookmark: bookmark))
        saveSources()
        rescanSources()
    }

    func removeSourceFolder(_ folder: SourceFolder) {
        sourceFolders.removeAll { $0.id == folder.id }
        if let idx = accessingSourceURLs.firstIndex(of: folder.url) {
            accessingSourceURLs[idx].stopAccessingSecurityScopedResource()
            accessingSourceURLs.remove(at: idx)
        }
        saveSources()
        rescanSources()
    }

    /// Re-indexes the source folders' media in the background. Cancels and
    /// replaces any scan already underway.
    func rescanSources() {
        scanTask?.cancel()
        let folders = sourceFolders.map(\.url)
        guard !folders.isEmpty else {
            sourceItems = []
            isScanningSources = false
            return
        }
        isScanningSources = true
        let projectURL = currentProjectURL
        scanTask = Task { [weak self] in
            let items = await SourceScanner.scan(folders: folders, excluding: projectURL)
            guard !Task.isCancelled else { return }
            self?.sourceItems = items
            self?.isScanningSources = false
        }
    }

    /// How many clips were picked from this source item ("Added ✓" badge) —
    /// counting both the still and, for a Live Photo, its motion clip.
    func usageCount(of item: SourceItem) -> Int {
        var paths: Set<String> = [item.url.canonicalSourcePath]
        if let motion = item.motionURL { paths.insert(motion.canonicalSourcePath) }
        return clips.filter { ($0.sourcePath).map(paths.contains) ?? false }.count
    }

    /// What's available to review for a day: how many source videos (and their
    /// combined length) and how many source photos fall on it. Drives the
    /// per-day footage hint in the calendar, independent of what's been picked.
    func availability(on day: Date) -> DayAvailability {
        let key = Calendar.current.startOfDay(for: day)
        return tally(sourceItemsByDay()[key] ?? [])
    }

    /// Same tally across a whole month, for the calendar header (one scan per
    /// header render, so a plain filter is fine — no month index needed).
    func availability(inMonthOf month: Date) -> DayAvailability {
        tally(sourceItems.filter { ($0.captureDate?.isSameMonth(as: month)) ?? false })
    }

    private func tally(_ items: [SourceItem]) -> DayAvailability {
        var result = DayAvailability()
        for item in items {
            switch item.kind {
            case .video:
                result.videoCount += 1
                result.videoDuration += item.duration ?? 0
            case .photo:
                result.photoCount += 1
            }
        }
        return result
    }

    /// Source items grouped by capture day (`startOfDay`), built lazily and
    /// cached until `sourceItems` changes. Undated items (no `captureDate`) are
    /// left out — they're reviewed in their own bucket, not placed on a day.
    private func sourceItemsByDay() -> [Date: [SourceItem]] {
        if let sourceItemsByDayCache { return sourceItemsByDayCache }
        let cal = Calendar.current
        var index: [Date: [SourceItem]] = [:]
        for item in sourceItems {
            guard let date = item.captureDate else { continue }
            index[cal.startOfDay(for: date), default: []].append(item)
        }
        sourceItemsByDayCache = index
        return index
    }

    /// Clips grouped by their calendar day (`startOfDay`), built lazily and
    /// cached until `clips` changes. Backs the per-day calendar/editor queries.
    private func clipsByDay() -> [Date: [Clip]] {
        if let clipsByDayCache { return clipsByDayCache }
        let cal = Calendar.current
        var index: [Date: [Clip]] = [:]
        for clip in clips {
            index[cal.startOfDay(for: clip.date), default: []].append(clip)
        }
        clipsByDayCache = index
        return index
    }

    // MARK: - Queries

    func clips(on day: Date, taggedWith tag: String? = nil) -> [Clip] {
        let key = Calendar.current.startOfDay(for: day)
        return (clipsByDay()[key] ?? [])
            .filter { $0.matches(tagFilter: tag) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Source items captured on a day, in capture order — the day window's
    /// "Available" rail. Undated items are excluded (they live in the review
    /// flow's undated bucket, not on any day).
    func sourceItems(on day: Date) -> [SourceItem] {
        let key = Calendar.current.startOfDay(for: day)
        return sourceItemsByDay()[key] ?? []
    }

    /// The nearest day before/after `day` that has either picked clips or source
    /// media — the day window's day-stepping. nil at the ends. Reuses the cached
    /// day groupings, so it only scans the (small) set of distinct days.
    func adjacentContentDay(from day: Date, forward: Bool) -> Date? {
        let key = Calendar.current.startOfDay(for: day)
        var days = Set(clipsByDay().keys)
        days.formUnion(sourceItemsByDay().keys)
        return forward ? days.filter { $0 > key }.min()
                       : days.filter { $0 < key }.max()
    }

    /// Whether any clip matches the tag filter — a cheap, short-circuiting test
    /// for enabling Create Video, instead of building a filtered array of the
    /// whole (possibly multi-thousand-clip) library just to check emptiness.
    func hasClips(taggedWith tag: String? = nil) -> Bool {
        clips.contains { $0.matches(tagFilter: tag) }
    }

    /// Every distinct tag in the library, alphabetical, for quick reuse.
    /// Case-insensitive: the alphabetically first spelling wins.
    var allTags: [String] {
        var seen = Set<String>()
        return clips.flatMap(\.tags)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    func clips(inMonthOf month: Date, taggedWith tag: String? = nil) -> [Clip] {
        clips.filter { $0.date.isSameMonth(as: month) && $0.matches(tagFilter: tag) }
            .sorted {
                $0.date == $1.date ? $0.createdAt < $1.createdAt : $0.date < $1.date
            }
    }

    /// Clips whose day falls inside an arbitrary render range (month, year, all
    /// or custom), tag-filtered, in the same date-then-createdAt order Preview
    /// and Export stitch them.
    func clips(in range: RenderRange, taggedWith tag: String? = nil) -> [Clip] {
        clips.filter { range.contains($0.date) && $0.matches(tagFilter: tag) }
            .sorted {
                $0.date == $1.date ? $0.createdAt < $1.createdAt : $0.date < $1.date
            }
    }

    // MARK: - Mutations

    /// Copies the file into the library and registers a clip for it.
    /// Videos and photos are both accepted; the clip's day defaults to the
    /// recording date when available.
    func importMedia(from sourceURL: URL) async {
        guard hasProject else { return }
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        let isImage = UTType(filenameExtension: sourceURL.pathExtension.lowercased())?
            .conforms(to: .image) == true
        if isImage {
            importPhoto(from: sourceURL)
        } else {
            await importVideo(from: sourceURL)
        }
    }

    private func importVideo(from sourceURL: URL) async {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let newName = UUID().uuidString + "." + ext
        let destURL = clipsDir.appendingPathComponent(newName)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            let asset = AVURLAsset(url: destURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                try? FileManager.default.removeItem(at: destURL)
                lastError = "\(sourceURL.lastPathComponent) doesn't look like a playable video."
                return
            }

            var clipDate = Date()
            if let item = try? await asset.load(.creationDate),
               let dateValue = try? await item.load(.dateValue) {
                clipDate = dateValue
            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
                      let created = attrs[.creationDate] as? Date {
                clipDate = created
            }

            var clip = Clip(
                fileName: newName,
                date: clipDate.dayKey,
                inSeconds: 0,
                outSeconds: duration,
                durationSeconds: duration
            )
            if let digest = Self.contentDigest(of: destURL) {
                clip.sourceHash = digest.hash
                clip.sourceBytes = digest.bytes
            }
            clips.append(clip)
            save()
        } catch {
            lastError = "Import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Moves a video the app itself produced (e.g. a per-day segment cut
    /// from a 1SE export) into the library and registers it for `date`.
    /// 1SE segments pass `showsDateOverlay: false` — their frames already
    /// carry a burned-in stamp.
    func adoptVideo(at tempURL: URL, date: Date, showsDateOverlay: Bool = true) async {
        guard hasProject else { return }
        let newName = UUID().uuidString + ".mp4"
        let destURL = clipsDir.appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            let asset = AVURLAsset(url: destURL)
            let duration = try await asset.load(.duration).seconds
            var clip = Clip(
                fileName: newName,
                date: date.dayKey,
                inSeconds: 0,
                outSeconds: duration,
                durationSeconds: duration,
                showsDateOverlay: showsDateOverlay
            )
            if let digest = Self.contentDigest(of: destURL) {
                clip.sourceHash = digest.hash
                clip.sourceBytes = digest.bytes
            }
            clips.append(clip)
            save()
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

    /// SHA-256 (lowercase hex) and byte size of a file's contents, streamed in
    /// 1 MB chunks so large videos aren't loaded into memory. Recorded on each
    /// clip's copied media so the project can be reconstructed by content if
    /// `Clips/` is lost. nil when the file can't be read.
    static func contentDigest(of url: URL) -> (hash: String, bytes: Int64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, bytes)
    }

    /// Copies `src` to `dst` in 1 MB chunks while hashing the bytes, so the file
    /// is read once for both the copy and its SHA-256 (a separate `copyItem` +
    /// `contentDigest` would read it twice — wasteful across thousands of large
    /// clips). Returns the digest + byte count, or nil if the copy fails.
    /// Unlike `copyItem` it doesn't preserve file attributes; library copies
    /// don't need them.
    nonisolated static func copyComputingDigest(
        from src: URL, to dst: URL
    ) -> (hash: String, bytes: Int64)? {
        guard let input = try? FileHandle(forReadingFrom: src) else { return nil }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: dst.path, contents: nil),
              let output = try? FileHandle(forWritingTo: dst) else { return nil }
        defer { try? output.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
                bytes += Int64(chunk.count)
            }
        } catch {
            try? FileManager.default.removeItem(at: dst)
            return nil
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, bytes)
    }

    /// Imports one 1SE "Download Your Data" project (see `DataExportImport.swift`):
    /// copies each snippet's `video.mov` into `Clips/` untrimmed and registers it
    /// on its timeline day, with the date stamp on (these raw snippets aren't
    /// pre-stamped, unlike a mashed-video import). `snippets` arrive in 1SE play
    /// order; within a day that order is preserved by seeding `createdAt` from the
    /// day plus an in-day index, so any clip added later still lands last. The
    /// heavy copy+hash runs off the main actor and clips are flushed/saved in
    /// batches, so a multi-thousand-clip import stays responsive and a partial
    /// run survives interruption. `progress` reports clips processed (1...count).
    func importDataExportProject(
        _ snippets: [DataExportSnippet],
        progress: @MainActor (Int) -> Void
    ) async {
        guard hasProject, let dir = clipsDir else { return }
        var batch: [Clip] = []
        var lastDay: Date?
        var inDayIndex = 0
        for (i, snippet) in snippets.enumerated() {
            if snippet.date == lastDay {
                inDayIndex += 1
            } else {
                inDayIndex = 0
                lastDay = snippet.date
            }
            let createdAt = snippet.date.addingTimeInterval(Double(inDayIndex))
            if let clip = await Self.adoptDataExportSnippet(
                videoURL: snippet.videoURL, into: dir,
                date: snippet.date, createdAt: createdAt, caption: snippet.caption
            ) {
                batch.append(clip)
            }
            if batch.count >= 100 {
                clips.append(contentsOf: batch)
                batch.removeAll(keepingCapacity: true)
                save()
            }
            progress(i + 1)
        }
        if !batch.isEmpty {
            clips.append(contentsOf: batch)
            save()
        }
    }

    /// Copies one export snippet's video into `clipsDir` (hashing in the same
    /// pass) and builds its full-length `Clip`. nil if the copy fails or the
    /// file isn't a playable video. Runs off the main actor.
    nonisolated private static func adoptDataExportSnippet(
        videoURL: URL, into clipsDir: URL, date: Date, createdAt: Date, caption: String
    ) async -> Clip? {
        let newName = UUID().uuidString + ".mov"
        let destURL = clipsDir.appendingPathComponent(newName)
        guard let digest = copyComputingDigest(from: videoURL, to: destURL) else {
            return nil
        }
        let asset = AVURLAsset(url: destURL)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration.isFinite, duration > 0 else {
            try? FileManager.default.removeItem(at: destURL)
            return nil
        }
        var clip = Clip(
            fileName: newName,
            date: date,
            inSeconds: 0,
            outSeconds: duration,
            durationSeconds: duration,
            createdAt: createdAt,
            caption: caption
        )
        clip.sourceHash = digest.hash
        clip.sourceBytes = digest.bytes
        return clip
    }

    /// How long an imported photo is shown by default, in seconds.
    static let defaultPhotoDuration = 3.0

    private func importPhoto(from sourceURL: URL) {
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let newName = UUID().uuidString + "." + ext
        let destURL = clipsDir.appendingPathComponent(newName)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            guard let source = CGImageSourceCreateWithURL(destURL as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else {
                try? FileManager.default.removeItem(at: destURL)
                lastError = "\(sourceURL.lastPathComponent) doesn't look like a readable image."
                return
            }

            var clipDate = Date()
            if let taken = exifCreationDate(of: source) {
                clipDate = taken
            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
                      let created = attrs[.creationDate] as? Date {
                clipDate = created
            }

            var clip = Clip(
                fileName: newName,
                date: clipDate.dayKey,
                inSeconds: 0,
                outSeconds: Self.defaultPhotoDuration,
                durationSeconds: Self.defaultPhotoDuration,
                kind: .photo
            )
            if let digest = Self.contentDigest(of: destURL) {
                clip.sourceHash = digest.hash
                clip.sourceBytes = digest.bytes
            }
            clips.append(clip)
            save()
        } catch {
            lastError = "Import failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Registers `draft` (trimmed/cropped/tagged in the review window) as a
    /// clip picked from source `item`, copying the file into the library —
    /// or reusing the existing copy when this source was picked before, so
    /// several segments of one long video share one media file.
    /// `from` selects which file to copy: the item's still by default, or its
    /// Live Photo motion clip when the user chose to add that instead. The
    /// still and the motion are distinct sources, so picking both yields two
    /// clips (and two copies), while re-picking the same one reuses its copy.
    func pick(_ item: SourceItem, draft: Clip, from sourceURL: URL? = nil) {
        guard hasProject else { return }
        let source = sourceURL ?? item.url
        var clip = draft
        clip.id = UUID()
        clip.createdAt = Date()
        let sourcePath = source.canonicalSourcePath
        clip.sourcePath = sourcePath
        if let existing = clips.first(where: { $0.sourcePath == sourcePath }) {
            clip.fileName = existing.fileName
            // Same bytes as the shared copy — reuse its digest instead of
            // re-hashing (e.g. two segments cut from one long video).
            clip.sourceHash = existing.sourceHash
            clip.sourceBytes = existing.sourceBytes
        } else {
            let fallbackExt = clip.kind == .photo ? "jpg" : "mov"
            let ext = source.pathExtension.isEmpty ? fallbackExt : source.pathExtension
            let newName = UUID().uuidString + "." + ext
            do {
                try FileManager.default.copyItem(
                    at: source, to: clipsDir.appendingPathComponent(newName)
                )
            } catch {
                lastError = "Could not copy \(source.lastPathComponent): \(error.localizedDescription)"
                return
            }
            clip.fileName = newName
            if let digest = Self.contentDigest(of: source) {
                clip.sourceHash = digest.hash
                clip.sourceBytes = digest.bytes
            }
        }
        clips.append(clip)
        save()
        // Remember a photo's duration so the next photo reviewed defaults to it.
        if clip.kind == .photo, settings.lastPhotoDuration != clip.durationSeconds {
            updateSettings { $0.lastPhotoDuration = clip.durationSeconds }
        }
    }

    func update(_ clip: Clip) {
        guard let idx = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var clip = clip
        // Within-day order is managed solely through `reorderClips` (which
        // reassigns `createdAt`). Editors snapshot a clip on open and write it
        // back wholesale here, so preserve the stored `createdAt` — otherwise a
        // reorder made while an editor is open would be clobbered by its stale
        // snapshot on save.
        clip.createdAt = clips[idx].createdAt
        // The day/photo editors save on disappear, so just clicking through a
        // day's clips (or closing the editor untouched) would otherwise
        // re-encode and rewrite the entire library each time — skip the write
        // when nothing actually changed.
        guard clips[idx] != clip else { return }
        if clips[idx].thumbnailKey != clip.thumbnailKey {
            thumbnailCache.removeObject(forKey: clip.id as NSUUID)
        }
        clips[idx] = clip
        save()
    }

    /// Imposes a new within-day order on `day`'s clips, e.g. after a drag in
    /// the day editor — letting clips run out of strict chronological order
    /// when that makes for nicer transitions. Order within a day is keyed only
    /// on `createdAt`, so this reassigns those timestamps to match `orderedIDs`:
    /// strictly increasing, 1s apart, anchored at the day's earliest existing
    /// `createdAt` so the values stay plausible. The calendar, preview and
    /// export all already sort by `createdAt`, so they follow automatically.
    /// `orderedIDs` must be exactly the day's clips, reordered.
    func reorderClips(on day: Date, orderedIDs: [UUID]) {
        let existing = clips(on: day)
        guard orderedIDs.count == existing.count,
              Set(orderedIDs) == Set(existing.map(\.id)) else { return }
        let base = existing.map(\.createdAt).min() ?? Date()
        for (offset, id) in orderedIDs.enumerated() {
            guard let idx = clips.firstIndex(where: { $0.id == id }) else { continue }
            clips[idx].createdAt = base.addingTimeInterval(Double(offset))
        }
        save()
    }

    func delete(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        // Card clips have no media file in `Clips/` (they render from their card
        // document). For real media, clips picked twice from one source share a
        // file — only remove it when the last of them goes.
        if !clip.isCard,
           !clips.contains(where: { $0.fileName == clip.fileName }) {
            try? FileManager.default.removeItem(at: fileURL(for: clip))
        }
        thumbnailCache.removeObject(forKey: clip.id as NSUUID)
        save()
    }

    // MARK: - Cards

    /// Where a card is currently used across the project. Drives the card
    /// editor's "Where it's used" panel so the user can judge the blast radius of
    /// an edit (and decide to duplicate first). Since every use is a live
    /// reference, editing a card affects every entry here on the next render.
    struct CardUsage {
        /// Human labels of the render periods using the card as cover / ending.
        var coverPeriods: [String]
        var endingPeriods: [String]
        /// Days the card is placed on, with how many times it appears on each.
        var days: [(date: Date, count: Int)]
        var isEmpty: Bool { coverPeriods.isEmpty && endingPeriods.isEmpty && days.isEmpty }

        /// Total placements: covers + endings + every day appearance.
        var total: Int {
            coverPeriods.count + endingPeriods.count + days.reduce(0) { $0 + $1.count }
        }
    }

    /// Tallies the cover/ending periods and the days where card `id` is used.
    func cardUsage(of id: UUID) -> CardUsage {
        func periods(_ pick: (BookendSettings) -> UUID?) -> [String] {
            settings.bookendsByPeriod
                .filter { pick($0.value) == id }
                .compactMap { RenderRange(periodKey: $0.key) }
                .sorted { $0.anchorDate < $1.anchorDate }
                .map(\.label)
        }
        let grouped = Dictionary(grouping: clips.filter { $0.cardID == id },
                                 by: { $0.date.dayKey })
        let days = grouped.map { (date: $0.key, count: $0.value.count) }
            .sorted { $0.date < $1.date }
        return CardUsage(coverPeriods: periods(\.coverCardID),
                         endingPeriods: periods(\.endingCardID),
                         days: days)
    }

    /// Loads every saved card by scanning `Cards/<id>/card.json`, sorted by
    /// name. Unreadable folders are skipped rather than failing the load.
    private static func loadCards(from dir: URL) -> [CardDocument] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        let docs = entries.compactMap { entry -> CardDocument? in
            let url = entry.appendingPathComponent("card.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(CardDocument.self, from: data)
        }
        return docs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The folder holding a card's `card.json` and its image assets.
    func cardDir(for doc: CardDocument) -> URL {
        cardsDir.appendingPathComponent(doc.id.uuidString, isDirectory: true)
    }

    /// On-disk URL of one of a card's image assets.
    func cardAssetURL(card: CardDocument, assetID: String) -> URL {
        cardDir(for: card).appendingPathComponent(assetID)
    }

    /// Whether `name` (case-insensitively) is free for a card, ignoring the card
    /// with `excluding` (so saving a card under its own name is allowed).
    func cardNameAvailable(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !cards.contains {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// A free card name based on `base`, appending "copy" / "copy N" as needed.
    private func uniqueCardName(basedOn base: String) -> String {
        var candidate = "\(base) copy"
        var n = 2
        while !cardNameAvailable(candidate) {
            candidate = "\(base) copy \(n)"
            n += 1
        }
        return candidate
    }

    /// Writes a card's `card.json` and registers it (or updates the existing
    /// entry). The folder is created on demand, so a brand-new card's assets can
    /// be stored before its first save.
    func saveCard(_ doc: CardDocument) {
        guard cardsDir != nil else { return }
        let dir = cardDir(for: doc)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doc)
            try data.write(to: dir.appendingPathComponent("card.json"), options: .atomic)
        } catch {
            lastError = "Could not save card “\(doc.name)”: \(error.localizedDescription)"
            return
        }
        if let idx = cards.firstIndex(where: { $0.id == doc.id }) {
            cards[idx] = doc
        } else {
            cards.append(doc)
        }
        cards.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Drop cached thumbnails of this card's day placements so the calendar
        // and rail re-render its new design (their task ids change too, via
        // `thumbnailKey(for:)`, which folds in the card's hash).
        for clip in clips where clip.cardID == doc.id {
            thumbnailCache.removeObject(forKey: clip.id as NSUUID)
        }
    }

    /// Copies a card's folder (assets included) under a new id + "copy" name.
    @discardableResult
    func duplicateCard(_ doc: CardDocument) -> CardDocument? {
        guard cardsDir != nil else { return nil }
        var copy = doc
        copy.id = UUID()
        copy.name = uniqueCardName(basedOn: doc.name)
        do {
            try FileManager.default.copyItem(at: cardDir(for: doc), to: cardDir(for: copy))
        } catch {
            lastError = "Could not duplicate card “\(doc.name)”: \(error.localizedDescription)"
            return nil
        }
        // Overwrite the copied card.json with the new id/name (assets keep their
        // names, and elements address them by name within this folder).
        saveCard(copy)
        return copy
    }

    func deleteCard(_ doc: CardDocument) {
        try? FileManager.default.removeItem(at: cardDir(for: doc))
        cards.removeAll { $0.id == doc.id }
    }

    /// Removes a never-saved card's folder (e.g. its pasted assets) when the
    /// editor is cancelled, so trying out a new card leaves nothing behind.
    func discardUnsavedCard(_ doc: CardDocument) {
        guard !cards.contains(where: { $0.id == doc.id }) else { return }
        try? FileManager.default.removeItem(at: cardDir(for: doc))
    }

    /// Copies an image file into a card's folder, returning the new asset id
    /// (the stored file name) to reference from a `.image` element.
    func importCardImage(from url: URL, into doc: CardDocument) -> String? {
        let dir = cardDir(for: doc)
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let assetID = UUID().uuidString + "." + ext
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(assetID))
            return assetID
        } catch {
            lastError = "Could not add image: \(error.localizedDescription)"
            return nil
        }
    }

    /// Stores a pasted image as a PNG card asset, returning its asset id.
    func importCardImage(_ image: NSImage, into doc: CardDocument) -> String? {
        let dir = cardDir(for: doc)
        guard let data = image.pngData() else {
            lastError = "Could not read the pasted image."
            return nil
        }
        let assetID = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(assetID), options: .atomic)
            return assetID
        } catch {
            lastError = "Could not add the pasted image: \(error.localizedDescription)"
            return nil
        }
    }

    /// Renders a card to an image at `size`, loading its image assets from the
    /// card's folder. The single rendering path for the editor canvas, gallery
    /// thumbnails, day snapshots and cover/ending segments.
    func renderCardImage(_ doc: CardDocument, size: CGSize) -> CGImage? {
        let maxPixel = Int(max(size.width, size.height).rounded())
        var assets: [String: CGImage] = [:]
        for element in doc.elements {
            if case .image(let assetID) = element.kind, assets[assetID] == nil {
                if let cg = loadOrientedCGImage(from: cardAssetURL(card: doc, assetID: assetID),
                                                maxPixel: maxPixel) {
                    assets[assetID] = cg
                }
            }
        }
        return CardRenderer.drawCard(doc, assets: assets, size: size)
    }

    /// Registers `doc` as a **live card reference** clip on `day`: no media file
    /// is written — the card is rendered fresh from its current document wherever
    /// the clip is shown (thumbnail, preview, export), so later edits to the card
    /// flow through. The display duration is per-placement (seeded from the card
    /// default, editable in the photo editor); the date stamp is off (cards are
    /// already composed).
    func addCard(_ doc: CardDocument, to day: Date) {
        guard hasProject else { return }
        let clip = Clip(
            fileName: "",
            date: day.dayKey,
            inSeconds: 0,
            outSeconds: Card.defaultDisplaySeconds,
            durationSeconds: Card.defaultDisplaySeconds,
            kind: .photo,
            cardID: doc.id,
            showsDateOverlay: false
        )
        clips.append(clip)
        save()
    }

    // MARK: - Thumbnails

    /// Cache/task key for a clip's thumbnail. A card clip folds in its card's
    /// current design (its `Hashable` value), so editing a card refires the
    /// views' regeneration tasks and refreshes its placements' thumbnails.
    func thumbnailKey(for clip: Clip) -> String {
        guard let cardID = clip.cardID else { return clip.thumbnailKey }
        let version = cards.first(where: { $0.id == cardID })?.hashValue ?? 0
        return "\(clip.thumbnailKey)|card:\(version)"
    }

    /// A card-aspect thumbnail size with the longer side ~480px.
    private func thumbnailSize(for aspect: ProjectSettings.Orientation) -> CGSize {
        let s = aspect.size
        let scale = 480 / max(s.width, s.height)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    /// Thumbnail at the clip's in-point (or the photo itself), cached in memory.
    func thumbnail(for clip: Clip) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: clip.id as NSUUID) {
            return cached
        }
        // Card clips have no media file — render the card document fresh.
        if let cardID = clip.cardID {
            guard let doc = cards.first(where: { $0.id == cardID }),
                  let cg = renderCardImage(doc, size: thumbnailSize(for: doc.aspect)) else {
                return nil
            }
            let image = NSImage(cgImage: cg, size: .zero)
            thumbnailCache.setObject(image, forKey: clip.id as NSUUID)
            return image
        }
        if clip.kind == .photo {
            guard var cg = loadOrientedCGImage(from: fileURL(for: clip), maxPixel: 480) else {
                return nil
            }
            if let crop = clip.crop {
                cg = croppedImage(cg, to: crop)
            }
            let image = NSImage(cgImage: cg, size: .zero)
            thumbnailCache.setObject(image, forKey: clip.id as NSUUID)
            return image
        }
        let asset = AVURLAsset(url: fileURL(for: clip))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: clip.inSeconds, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            let image = NSImage(cgImage: cgImage, size: .zero)
            thumbnailCache.setObject(image, forKey: clip.id as NSUUID)
            return image
        } catch {
            return nil
        }
    }

    /// Thumbnail for a not-yet-picked source item (the still for a photo / Live
    /// Photo, an early frame for a video), cached in memory by file path.
    func thumbnail(for item: SourceItem) async -> NSImage? {
        let key = item.id as NSString
        if let cached = sourceThumbnailCache.object(forKey: key) {
            return cached
        }
        if item.kind == .photo {
            guard let cg = loadOrientedCGImage(from: item.url, maxPixel: 480) else {
                return nil
            }
            let image = NSImage(cgImage: cg, size: .zero)
            sourceThumbnailCache.setObject(image, forKey: key)
            return image
        }
        let asset = AVURLAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        // A frame slightly in (not 0) avoids the occasional black first frame.
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            let image = NSImage(cgImage: cgImage, size: .zero)
            sourceThumbnailCache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}

/// Decodes an image with its EXIF orientation baked in, downscaled so the
/// longest side is at most `maxPixel`. Crop coordinates are always relative
/// to this oriented image, so the editor and the exporter agree.
nonisolated func loadOrientedCGImage(from url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// Applies a clip's normalized crop to an oriented image. Shared by the
/// thumbnail generator and the export's photo-segment renderer.
nonisolated func croppedImage(_ image: CGImage, to crop: CropRect) -> CGImage {
    guard !crop.isFull else { return image }
    let pixelRect = CGRect(
        x: crop.x * Double(image.width),
        y: crop.y * Double(image.height),
        width: crop.width * Double(image.width),
        height: crop.height * Double(image.height)
    ).integral
    return image.cropping(to: pixelRect) ?? image
}

// MARK: - Project pickers

/// A recently opened project: its resolved location plus the security-scoped
/// bookmark needed to reopen it.
struct RecentProject: Identifiable {
    let url: URL
    let bookmark: Data
    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
}

/// A folder whose photos/videos feed the review window: resolved location
/// plus the security-scoped bookmark that regains access across launches.
struct SourceFolder: Identifiable {
    let url: URL
    let bookmark: Data
    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
}

/// On-disk form of a source folder (`sources.json` in the project root).
/// Keeps the path alongside the bookmark for human readability.
private struct SourceFolderRecord: Codable {
    var bookmark: Data
    var path: String
}

/// Save-panel flow for creating a new project folder (name + location).
@MainActor
func presentNewProjectPanel(store: LibraryStore) {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldLabel = "Project name:"
    panel.nameFieldStringValue = "Untitled Project"
    panel.prompt = "Create"
    panel.message = "Choose where to create your ClipDiary project."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.createProject(at: url)
}

/// Open-panel flow for opening an existing project directory.
@MainActor
func presentOpenProjectPanel(store: LibraryStore) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a ClipDiary project folder."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.openProject(at: url)
}
