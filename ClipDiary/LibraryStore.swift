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

    private var clipsDir: URL!
    private var metadataURL: URL!
    /// The security-scoped URL we currently hold access to (released before we
    /// switch to another project). nil for open/save-panel URLs, which the
    /// sandbox keeps accessible for the whole process without start/stop.
    private var accessingScopedURL: URL?
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

    private func load() {
        guard let metadataURL, let data = try? Data(contentsOf: metadataURL) else {
            clips = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        clips = (try? decoder.decode([Clip].self, from: data)) ?? []
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
    func restoreLastProject() {
        guard let data = UserDefaults.standard.data(forKey: Keys.lastBookmark) else { return }
        if !openFromBookmark(data) {
            UserDefaults.standard.removeObject(forKey: Keys.lastBookmark)
        }
    }

    /// Resolves a stored bookmark, takes security-scoped access, and opens the
    /// project. Returns false if it can't be resolved/accessed or isn't a
    /// project (caller prunes the dead bookmark).
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
        if activateProject(at: url, takeScope: true) { return true }
        forgetBookmark(data)
        return false
    }

    /// Switches to `url`: releases the previous scope, optionally takes
    /// security-scoped access, loads its clips, and records it as last-used +
    /// most-recent. Returns false (without switching) if it isn't a project.
    @discardableResult
    private func activateProject(at url: URL, takeScope: Bool) -> Bool {
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("clips.json").path
        ) else {
            if takeScope { url.stopAccessingSecurityScopedResource() }
            lastError = "“\(url.lastPathComponent)” isn’t a ClipDiary project (no clips.json). Use New Project to create one."
            return false
        }
        releaseCurrentScope()
        accessingScopedURL = takeScope ? url : nil

        currentProjectURL = url
        clipsDir = url.appendingPathComponent("Clips", isDirectory: true)
        metadataURL = url.appendingPathComponent("clips.json")
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        thumbnailCache.removeAllObjects()
        load()
        rememberProject(url)
        return true
    }

    private func releaseCurrentScope() {
        accessingScopedURL?.stopAccessingSecurityScopedResource()
        accessingScopedURL = nil
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

    // MARK: - Queries

    func clips(on day: Date, taggedWith tag: String? = nil) -> [Clip] {
        clips.filter { $0.date.isSameDay(as: day) && $0.matches(tagFilter: tag) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Every distinct tag in the library, alphabetical, for quick reuse.
    /// Case-insensitive: the first spelling encountered wins.
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
            if let taken = Self.exifCreationDate(of: source) {
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

    /// "Date taken" from EXIF/TIFF metadata, e.g. "2026:06:07 18:21:05".
    private static func exifCreationDate(of source: CGImageSource) -> Date? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let string = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? tiff?[kCGImagePropertyTIFFDateTime] as? String else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string)
    }

    func update(_ clip: Clip) {
        guard let idx = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[idx] = clip
        save()
    }

    func delete(_ clip: Clip) {
        try? FileManager.default.removeItem(at: fileURL(for: clip))
        thumbnailCache.removeObject(forKey: clip.id as NSUUID)
        clips.removeAll { $0.id == clip.id }
        save()
    }

    // MARK: - Thumbnails

    /// Thumbnail at the clip's in-point (or the photo itself), cached in memory.
    func thumbnail(for clip: Clip) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: clip.id as NSUUID) {
            return cached
        }
        if clip.kind == .photo {
            guard let cg = loadOrientedCGImage(from: fileURL(for: clip), maxPixel: 480) else {
                return nil
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

// MARK: - Project pickers

/// A recently opened project: its resolved location plus the security-scoped
/// bookmark needed to reopen it.
struct RecentProject: Identifiable {
    let url: URL
    let bookmark: Data
    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
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
