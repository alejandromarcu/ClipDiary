import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// One photo or video found inside a project's source folders. Source files
/// are never modified or moved; picking one in the review window copies it
/// into the project's `Clips/` folder.
struct SourceItem: Identifiable, Hashable {
    let url: URL
    let kind: ClipKind
    /// Embedded capture date and time (EXIF DateTimeOriginal / QuickTime
    /// creation date). nil when the file carries no date — chat apps strip
    /// metadata, and a filesystem-date fallback would pin such files to the
    /// day the album was downloaded. Undated items are reviewed in a bucket
    /// after all dated days instead of being placed on a guessed day.
    let captureDate: Date?
    /// Duration in seconds, loaded during the scan: a standalone video's
    /// length, or — for a Live Photo — its motion clip's length. nil for plain
    /// photos or when it can't be read. Lets the calendar show a day's
    /// available footage length and the review window label the motion option.
    var duration: Double? = nil
    /// Live Photos only: the paired motion video sitting next to the still
    /// (same folder + basename). nil for everything else. When set, the item
    /// is a photo that can optionally be added as its short video instead.
    var motionURL: URL? = nil

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var isUndated: Bool { captureDate == nil }
    var isLivePhoto: Bool { motionURL != nil }
}

extension URL {
    /// Canonical path for recording/matching a clip's `sourcePath` across
    /// launches — security-scoped bookmark resolution can return equivalent
    /// but differently spelled paths (e.g. with a /private prefix).
    var canonicalSourcePath: String {
        standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Recursively walks source folders and indexes every photo and video with
/// its capture time. Pure file inspection — no UI, no project state.
enum SourceScanner {
    /// Scans `folders` (recursively, hidden files skipped) and returns the
    /// found media: dated items sorted by capture time, then the undated
    /// bucket sorted by path. Files under `excluded` — the project's own
    /// folder, whose `Clips/` holds copies — are ignored, as are duplicates
    /// when folders overlap.
    static func scan(folders: [URL], excluding excluded: URL?) async -> [SourceItem] {
        let files = enumerateMedia(in: folders, excluding: excluded)

        // Pair Live Photos: iPhone/Google exports write a still and its motion
        // clip side by side with the same basename (IMG_1234.JPG +
        // IMG_1234.MOV/.MP4). The still represents the moment; the video
        // becomes its optional motion, so the pair counts as one photo rather
        // than a phantom extra video. Indexes are built up front so the result
        // doesn't depend on filesystem enumeration order.
        var videoByStem: [String: URL] = [:]
        var stemsWithStill = Set<String>()
        for file in files {
            switch file.kind {
            case .video: videoByStem[stem(of: file.url)] = file.url
            case .photo: stemsWithStill.insert(stem(of: file.url))
            }
        }

        var items: [SourceItem] = []
        for file in files {
            if Task.isCancelled { return [] }
            switch file.kind {
            case .photo:
                let motion = videoByStem[stem(of: file.url)]
                let motionDuration = motion == nil
                    ? nil : await metadata(of: motion!, kind: .video).duration
                let date = await metadata(of: file.url, kind: .photo).date
                items.append(SourceItem(url: file.url, kind: .photo, captureDate: date,
                                        duration: motionDuration, motionURL: motion))
            case .video:
                // A video paired with a still is that Live Photo's motion, not
                // a standalone clip — it surfaces through the still instead.
                if stemsWithStill.contains(stem(of: file.url)) { continue }
                let meta = await metadata(of: file.url, kind: .video)
                items.append(SourceItem(url: file.url, kind: .video,
                                        captureDate: meta.date, duration: meta.duration))
            }
        }
        return items.sorted { a, b in
            switch (a.captureDate, b.captureDate) {
            case let (da?, db?):
                return da == db ? a.url.path < b.url.path : da < db
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.url.path < b.url.path
            }
        }
    }

    private struct FoundFile {
        let url: URL
        let kind: ClipKind
    }

    /// Directory walk only — capture dates are resolved separately because
    /// video metadata loading is async.
    private static func enumerateMedia(in folders: [URL], excluding excluded: URL?) -> [FoundFile] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey]
        var found: [FoundFile] = []
        var seenPaths = Set<String>()

        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if let excluded, url.path.hasPrefix(excluded.path + "/") { continue }
                guard seenPaths.insert(url.path).inserted,
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let type = values.contentType,
                      let kind = mediaKind(of: type)
                else { continue }
                found.append(FoundFile(url: url, kind: kind))
            }
        }
        return found
    }

    /// Folder + basename without extension, lowercased — the key that pairs a
    /// Live Photo's still with its motion clip regardless of extension casing.
    private static func stem(of url: URL) -> String {
        url.deletingPathExtension().path.lowercased()
    }

    private static func mediaKind(of type: UTType) -> ClipKind? {
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }

    /// Capture date (+ duration for videos), loaded together so a video's
    /// asset is only opened once.
    private static func metadata(of url: URL, kind: ClipKind) async -> (date: Date?, duration: Double?) {
        switch kind {
        case .photo:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, nil) }
            return (exifCreationDate(of: source), nil)
        case .video:
            let asset = AVURLAsset(url: url)
            var date: Date?
            if let item = try? await asset.load(.creationDate) {
                date = try? await item.load(.dateValue)
            }
            let seconds = try? await asset.load(.duration).seconds
            let duration = (seconds?.isFinite == true && seconds! > 0) ? seconds : nil
            return (date, duration)
        }
    }
}

/// "Date taken" from EXIF/TIFF metadata, e.g. "2026:06:07 18:21:05". Shared
/// by the scanner and the photo importer.
func exifCreationDate(of source: CGImageSource) -> Date? {
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
