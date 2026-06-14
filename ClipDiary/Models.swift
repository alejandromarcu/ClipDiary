import Foundation
import CoreGraphics

/// Whether a clip is a video file or a still photo.
enum ClipKind: String, Codable {
    case video, photo
}

/// Per-project render preferences, persisted next to the clips in
/// `settings.json`. Every field has a default and decodes with
/// `decodeIfPresent`, so projects created before settings existed (no file) —
/// and any future option added here — load cleanly with no migration.
struct ProjectSettings: Codable, Equatable {
    /// The month video's aspect/size, used for both Preview and Export.
    var orientation: Orientation = .landscape
    /// When true, the month video fades to black over its final
    /// `fadeOutSeconds` (video, audio and the date stamp together).
    var fadeOutLastClip: Bool = false
    /// Length of that fade, in seconds (ignored when `fadeOutLastClip` is off).
    var fadeOutSeconds: Double = 1.0

    /// The fade length to actually apply, or nil when fading is disabled.
    var effectiveFadeOutSeconds: Double? {
        fadeOutLastClip && fadeOutSeconds > 0 ? fadeOutSeconds : nil
    }

    enum Orientation: String, Codable, CaseIterable, Identifiable {
        case portrait, landscape
        var id: String { rawValue }
        var label: String {
            self == .portrait ? "Portrait (1080×1920)" : "Landscape (1920×1080)"
        }
        var size: CGSize {
            self == .portrait ? CGSize(width: 1080, height: 1920)
                              : CGSize(width: 1920, height: 1080)
        }
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case orientation, fadeOutLastClip, fadeOutSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .landscape
        fadeOutLastClip = try c.decodeIfPresent(Bool.self, forKey: .fadeOutLastClip) ?? false
        fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? 1.0
    }
}

/// Crop rectangle in unit image coordinates (origin top-left, values 0…1).
struct CropRect: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)
    var isFull: Bool { self == .full }
}

/// One video clip or photo assigned to a calendar day.
struct Clip: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    /// File name inside the app's library folder (we copy imports there).
    var fileName: String
    /// The calendar day this clip represents.
    var date: Date
    /// Trim in-point, in seconds from the start of the file.
    var inSeconds: Double = 0
    /// Trim out-point, in seconds from the start of the file.
    var outSeconds: Double
    /// Full duration of the source file, in seconds.
    var durationSeconds: Double
    /// Used to keep a stable order when a day has several clips.
    var createdAt: Date = Date()
    /// User-assigned tags, e.g. "beach" or "Isaac's best".
    var tags: [String] = []
    /// Video file or still photo. For photos, durationSeconds/outSeconds hold
    /// the chosen display duration and inSeconds is 0.
    var kind: ClipKind = .video
    /// Photos only: normalized crop (nil = whole image).
    var crop: CropRect? = nil
    /// Whether the month render burns this clip's date into the bottom-left
    /// corner. Off by default for 1SE imports, whose frames already carry a
    /// stamp; also handy off for cover photos.
    var showsDateOverlay: Bool = true
    /// Optional short caption rendered above the date stamp in the month video,
    /// e.g. "first time skating". Empty string means no caption.
    var caption: String = ""
    /// Path of the source-folder file this clip was picked from, if any.
    /// Several clips may share one source (and one copied media file), e.g.
    /// two segments cut from the same long video.
    var sourcePath: String? = nil

    var trimmedDuration: Double { max(0, outSeconds - inSeconds) }

    /// Changes when the frame a thumbnail shows would change: the clip's
    /// identity, its trim in-point (videos) or its crop (photos). Views use
    /// it as a task id to regenerate thumbnails; the store uses it to drop
    /// stale cache entries on update.
    var thumbnailKey: String {
        let cropKey = crop.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "full"
        return "\(id.uuidString)|\(inSeconds)|\(cropKey)"
    }

    /// True when no tag filter is set, or the clip carries the tag
    /// (case-insensitive, matching how tags are deduped).
    func matches(tagFilter: String?) -> Bool {
        guard let tagFilter else { return true }
        return tags.contains { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, date, inSeconds, outSeconds, durationSeconds, createdAt,
             tags, kind, crop, showsDateOverlay, caption, sourcePath
    }
}

extension Clip {
    /// Libraries saved before tags existed have no `tags` key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        date = try container.decode(Date.self, forKey: .date)
        inSeconds = try container.decode(Double.self, forKey: .inSeconds)
        outSeconds = try container.decode(Double.self, forKey: .outSeconds)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        kind = try container.decodeIfPresent(ClipKind.self, forKey: .kind) ?? .video
        crop = try container.decodeIfPresent(CropRect.self, forKey: .crop)
        showsDateOverlay = try container.decodeIfPresent(Bool.self, forKey: .showsDateOverlay) ?? true
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
    }
}

/// The 1SE-style date stamp rendered into the bottom-left corner of the
/// month video. Sizes are fractions of the render's smaller side so the
/// export and the in-app preview agree.
enum DateStamp {
    static let fontFraction: CGFloat = 0.053
    static let leftMarginFraction: CGFloat = 0.070
    static let bottomMarginFraction: CGFloat = 0.07
    /// Letter-spacing as a fraction of the font size (1SE tracks the stamp out).
    static let trackingFraction: CGFloat = 0.08

    /// e.g. "MAR 03 2026", matching the stamp 1SE burns into its exports.
    static func text(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd yyyy"
        return formatter.string(from: date).uppercased()
    }
}

/// What a calendar day has waiting in the project's source folders: the count
/// and combined length of its videos, plus its photo count. Shown as a hint on
/// each day cell whether or not clips have been picked yet.
struct DayAvailability {
    var videoCount = 0
    var videoDuration = 0.0
    var photoCount = 0

    var isEmpty: Bool { videoCount == 0 && photoCount == 0 }
}

/// Wraps a day so it can drive `.sheet(item:)`, instead of retroactively
/// conforming the system Date type to Identifiable.
struct DaySelection: Identifiable {
    let day: Date
    var id: Date { day }
}

extension Date {
    /// Start of the calendar day, used as the canonical key for a day.
    var dayKey: Date { Calendar.current.startOfDay(for: self) }

    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }

    func isSameMonth(as other: Date) -> Bool {
        let cal = Calendar.current
        return cal.component(.year, from: self) == cal.component(.year, from: other)
            && cal.component(.month, from: self) == cal.component(.month, from: other)
    }
}

func formatTime(_ seconds: Double) -> String {
    // Round to centiseconds before splitting, so 59.997 shows as
    // "1:00.00" rather than "0:60.00".
    let centiseconds = Int((max(0, seconds) * 100).rounded())
    let m = centiseconds / 6000
    let s = Double(centiseconds % 6000) / 100
    return String(format: "%d:%05.2f", m, s)
}

/// Coarse `m:ss` length (no fractional seconds) for at-a-glance totals like
/// a calendar day's available footage.
func formatDurationShort(_ seconds: Double) -> String {
    let total = Int(max(0, seconds).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
