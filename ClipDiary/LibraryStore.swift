import Foundation
import AVFoundation
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Owns the clip library for the **currently open project**: a user-chosen
/// directory holding `clips.json` (metadata) + a `Clips/` subfolder of copied
/// media files. The last-used project reopens across launches via a
/// security-scoped bookmark (the sandbox only grants persistent folder access
/// that way). With no project open the app shows its welcome screen.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    @Published var lastError: String?

    /// The open project's root directory, or nil when none is open.
    /// `clipsDir`/`metadataURL` are valid exactly when this is non-nil, so the
    /// file-accessing methods below are only reached with a project open.
    @Published private(set) var currentProjectURL: URL?

    /// The project's source folders (review-window inventory) and the media
    /// found inside them, sorted by capture time.
    @Published private(set) var sourceFolders: [SourceFolder] = []
    @Published private(set) var sourceItems: [SourceItem] = []
    @Published private(set) var isScanningSources = false

    /// The open project's render preferences (orientation, ending fade).
    /// Mutated only through `updateSettings`, which also persists.
    @Published private(set) var settings = ProjectSettings()

    private var clipsDir: URL!
    private var metadataURL: URL!
    private var sourcesURL: URL!
    private var settingsURL: URL!
    /// The security-scoped URL we currently hold access to (released before we
    /// switch to another project). nil for open/save-panel URLs, which the
    /// sandbox keeps accessible for the whole process without start/stop.
    private var accessingScopedURL: URL?
    /// Source folders we hold security-scoped access to (resolved from the
    /// project's stored bookmarks; released on project switch).
    private var accessingSourceURLs: [URL] = []
    private var scanTask: Task<Void, Never>?
    private let thumbnailCache = NSCache<NSUUID, NSImage>()

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
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        thumbnailCache.removeAllObjects()
        clips = loadedClips
        settings = Self.loadSettings(from: settingsURL)
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
        availability(where: { $0.isSameDay(as: day) })
    }

    /// Same tally across a whole month, for the calendar header.
    func availability(inMonthOf month: Date) -> DayAvailability {
        availability(where: { $0.isSameMonth(as: month) })
    }

    private func availability(where matches: (Date) -> Bool) -> DayAvailability {
        var result = DayAvailability()
        for item in sourceItems {
            guard let date = item.captureDate, matches(date) else { continue }
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

    // MARK: - Queries

    func clips(on day: Date, taggedWith tag: String? = nil) -> [Clip] {
        clips.filter { $0.date.isSameDay(as: day) && $0.matches(tagFilter: tag) }
            .sorted { $0.createdAt < $1.createdAt }
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

            let clip = Clip(
                fileName: newName,
                date: clipDate.dayKey,
                inSeconds: 0,
                outSeconds: duration,
                durationSeconds: duration
            )
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
            let clip = Clip(
                fileName: newName,
                date: date.dayKey,
                inSeconds: 0,
                outSeconds: duration,
                durationSeconds: duration,
                showsDateOverlay: showsDateOverlay
            )
            clips.append(clip)
            save()
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
        }
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

            let clip = Clip(
                fileName: newName,
                date: clipDate.dayKey,
                inSeconds: 0,
                outSeconds: Self.defaultPhotoDuration,
                durationSeconds: Self.defaultPhotoDuration,
                kind: .photo
            )
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
        }
        clips.append(clip)
        save()
    }

    func update(_ clip: Clip) {
        guard let idx = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        if clips[idx].thumbnailKey != clip.thumbnailKey {
            thumbnailCache.removeObject(forKey: clip.id as NSUUID)
        }
        clips[idx] = clip
        save()
    }

    func delete(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        // Clips picked twice from one source share a media file — only
        // remove it when the last of them goes.
        if !clips.contains(where: { $0.fileName == clip.fileName }) {
            try? FileManager.default.removeItem(at: fileURL(for: clip))
        }
        thumbnailCache.removeObject(forKey: clip.id as NSUUID)
        save()
    }

    // MARK: - Thumbnails

    /// Thumbnail at the clip's in-point (or the photo itself), cached in memory.
    func thumbnail(for clip: Clip) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: clip.id as NSUUID) {
            return cached
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
