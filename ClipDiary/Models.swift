import Foundation
import CoreGraphics

/// Whether a clip is a video file or a still photo.
enum ClipKind: String, Codable {
    case video, photo
}

/// The Cover/Ending cards (and their fades) chosen for one render period in the
/// Create Video window. Stored per period (keyed by `RenderRange.periodKey`) so
/// each month/year/custom span remembers its own bookends — selecting a card
/// for "2025" doesn't carry over to "May 2026".
struct BookendSettings: Codable, Equatable {
    /// The card shown at the very start of the rendered video, or nil for none.
    var coverCardID: UUID? = nil
    /// The card shown at the very end of the rendered video, or nil for none.
    var endingCardID: UUID? = nil
    /// Fade in/out for the cover and ending cards (the cards carry none).
    var coverTransition = SegmentTransition()
    var endingTransition = SegmentTransition()

    /// True when nothing is configured — no cards and no fades. Such an entry is
    /// dropped rather than stored so the period map stays sparse.
    var isDefault: Bool {
        coverCardID == nil && endingCardID == nil
            && coverTransition.isEmpty && endingTransition.isEmpty
    }
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
    /// The time range last chosen in the Create Video window, remembered per
    /// project. `nil` means "never changed" — the window then defaults to the
    /// current month, which keeps following the calendar instead of sticking.
    var renderRange: RenderRange? = nil
    /// Cover/Ending cards (and their fades) remembered **per render period**,
    /// keyed by `RenderRange.periodKey`. Picking a cover for "2025" and then
    /// switching the Create Video window to "May 2026" shows that period's own
    /// (initially empty) bookends; switching back restores 2025's. Use
    /// `bookends(for:)` / `setBookends(_:for:)` rather than touching this map.
    var bookendsByPeriod: [String: BookendSettings] = [:]
    /// The display duration last used for a photo, so the next photo reviewed
    /// defaults to it instead of always restarting at the standard default.
    var lastPhotoDuration: Double = LibraryStore.defaultPhotoDuration
    /// The calendar month last shown for this project, so reopening it returns
    /// to that month instead of the current one. `nil` → never navigated.
    var lastViewedMonth: Date? = nil

    /// The fade length to actually apply, or nil when fading is disabled.
    var effectiveFadeOutSeconds: Double? {
        fadeOutLastClip && fadeOutSeconds > 0 ? fadeOutSeconds : nil
    }

    /// The Cover/Ending bookends saved for `range`'s period (defaults if none).
    func bookends(for range: RenderRange) -> BookendSettings {
        bookendsByPeriod[range.periodKey] ?? BookendSettings()
    }

    /// Remember `bookends` for `range`'s period; a default (empty) value drops
    /// the entry so the map only holds periods the user actually configured.
    mutating func setBookends(_ bookends: BookendSettings, for range: RenderRange) {
        if bookends.isDefault {
            bookendsByPeriod[range.periodKey] = nil
        } else {
            bookendsByPeriod[range.periodKey] = bookends
        }
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
        case orientation, fadeOutLastClip, fadeOutSeconds, renderRange,
             bookendsByPeriod, lastPhotoDuration, lastViewedMonth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .landscape
        fadeOutLastClip = try c.decodeIfPresent(Bool.self, forKey: .fadeOutLastClip) ?? false
        fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? 1.0
        renderRange = try c.decodeIfPresent(RenderRange.self, forKey: .renderRange)
        bookendsByPeriod = try c.decodeIfPresent([String: BookendSettings].self, forKey: .bookendsByPeriod) ?? [:]
        lastPhotoDuration = try c.decodeIfPresent(Double.self, forKey: .lastPhotoDuration) ?? LibraryStore.defaultPhotoDuration
        lastViewedMonth = try c.decodeIfPresent(Date.self, forKey: .lastViewedMonth)
    }
}

/// A span of calendar days rendered into one video — a specific month, a
/// specific year, the whole project, or an explicit start…end. Chosen in the
/// Create Video window and used by both Preview and Export. Persists in
/// `settings.json` and rides along as the Preview window's value, so it stays
/// `Codable`/`Hashable` (both synthesized for enums with associated values).
enum RenderRange: Codable, Hashable {
    case month(Date)
    case year(Date)
    case all
    case custom(start: Date, end: Date)

    /// Whether `date`'s calendar day falls within the range (inclusive ends).
    func contains(_ date: Date) -> Bool {
        switch self {
        case .month(let anchor):
            return date.isSameMonth(as: anchor)
        case .year(let anchor):
            let cal = Calendar.current
            return cal.component(.year, from: date) == cal.component(.year, from: anchor)
        case .all:
            return true
        case .custom(let start, let end):
            let day = date.dayKey
            return day >= start.dayKey && day <= end.dayKey
        }
    }

    /// Human-readable label for titles and summaries, e.g. "June 2026", "2026",
    /// "All clips", "Jan 1, 2026 – Mar 31, 2026".
    var label: String {
        switch self {
        case .month(let anchor):
            return anchor.formatted(.dateTime.month(.wide).year())
        case .year(let anchor):
            return String(Calendar.current.component(.year, from: anchor))
        case .all:
            return "All clips"
        case .custom(let start, let end):
            let s = start.formatted(date: .abbreviated, time: .omitted)
            // A single-day range (e.g. the day editor's Preview Day) reads as
            // one date, not "Jun 14, 2026 – Jun 14, 2026".
            guard start.dayKey != end.dayKey else { return s }
            let e = end.formatted(date: .abbreviated, time: .omitted)
            return "\(s) – \(e)"
        }
    }

    /// Filename-safe version of `label` for the export's default save name.
    var fileNameLabel: String {
        switch self {
        case .month, .year:
            return label
        case .all:
            return "All"
        case .custom(let start, let end):
            let s = Self.fileDateFormatter.string(from: start)
            guard start.dayKey != end.dayKey else { return s }
            return "\(s)–\(Self.fileDateFormatter.string(from: end))"
        }
    }

    /// The capture date stamped into an exported file's metadata: the last day
    /// of the period at 11:59 pm (e.g. March 2026 → Mar 31, 2026 23:59). For
    /// `.all`, there's no fixed period end, so the last day that has a clip is
    /// used instead. Returns nil when there's nothing to anchor on.
    func exportCreationDate(clips: [Clip]) -> Date? {
        let cal = Calendar.current
        let endDay: Date?
        switch self {
        case .month(let anchor):
            if let dayRange = cal.range(of: .day, in: .month, for: anchor) {
                var comps = cal.dateComponents([.year, .month], from: anchor)
                comps.day = dayRange.count
                endDay = cal.date(from: comps)
            } else {
                endDay = nil
            }
        case .year(let anchor):
            var comps = cal.dateComponents([.year], from: anchor)
            comps.month = 12
            comps.day = 31
            endDay = cal.date(from: comps)
        case .custom(_, let end):
            endDay = end
        case .all:
            endDay = clips.map(\.date).max()
        }
        guard let day = endDay else { return nil }
        return cal.date(bySettingHour: 23, minute: 59, second: 0, of: day)
    }

    /// A canonical string identifying the *period* (not the exact anchor date),
    /// so any `.month` anchored anywhere in June 2025 keys the same as another.
    /// Used to remember per-period Cover/Ending bookends in `ProjectSettings`.
    var periodKey: String {
        let cal = Calendar.current
        switch self {
        case .month(let anchor):
            let c = cal.dateComponents([.year, .month], from: anchor)
            return String(format: "month:%04d-%02d", c.year ?? 0, c.month ?? 0)
        case .year(let anchor):
            return "year:\(cal.component(.year, from: anchor))"
        case .all:
            return "all"
        case .custom(let start, let end):
            return "custom:\(Self.fileDateFormatter.string(from: start.dayKey))..\(Self.fileDateFormatter.string(from: end.dayKey))"
        }
    }

    /// The representative date a range hangs off — its month/year, the start of
    /// a custom range, or today for `.all`. Used to seed the picker controls.
    var anchorDate: Date {
        switch self {
        case .month(let anchor), .year(let anchor): return anchor
        case .all: return Date()
        case .custom(let start, _): return start
        }
    }

    /// The same range with its year replaced (month and year cases only).
    func withYear(_ year: Int) -> RenderRange {
        let cal = Calendar.current
        switch self {
        case .month(let anchor):
            var comps = cal.dateComponents([.year, .month], from: anchor)
            comps.year = year
            return .month(cal.date(from: comps) ?? anchor)
        case .year(let anchor):
            var comps = cal.dateComponents([.year], from: anchor)
            comps.year = year
            return .year(cal.date(from: comps) ?? anchor)
        default:
            return self
        }
    }

    /// The same range with its month replaced (month case only).
    func withMonth(_ month: Int) -> RenderRange {
        guard case .month(let anchor) = self else { return self }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month], from: anchor)
        comps.month = month
        return .month(cal.date(from: comps) ?? anchor)
    }

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
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
    /// The sole sort key among a day's clips. Set to "now" at creation so new
    /// clips land last, but reassigned by the day editor's drag-to-reorder
    /// (`LibraryStore.reorderClips`) when the user wants a non-chronological
    /// order for nicer transitions.
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
    /// Lowercase-hex SHA-256 of the copied media file's bytes, recorded when the
    /// clip is created. Lets the project be reconstructed if `Clips/` is lost:
    /// source files can be re-found by content even after renames/moves, since
    /// `sourcePath` (and file names) aren't reliable. nil for clips made before
    /// this field existed.
    var sourceHash: String? = nil
    /// Byte size of that media file — a near-free pre-filter and sanity check
    /// when matching `sourceHash` against source files. nil pre-this-field.
    var sourceBytes: Int64? = nil
    /// Optional fade in/out applied to this clip's segment in the rendered
    /// video. Edited in the day editor and review window.
    var transition = SegmentTransition()
    /// Playback level for this clip's audio in the rendered video, 1.0 = 100%.
    /// 0 mutes; values above 1 boost the volume (the editor caps it at 4.0 =
    /// 400%). Videos only — photos are silent, so it's ignored for them.
    var volume: Double = 1.0

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
             tags, kind, crop, showsDateOverlay, caption, sourcePath,
             sourceHash, sourceBytes, transition, volume
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
        sourceHash = try container.decodeIfPresent(String.self, forKey: .sourceHash)
        sourceBytes = try container.decodeIfPresent(Int64.self, forKey: .sourceBytes)
        transition = try container.decodeIfPresent(SegmentTransition.self, forKey: .transition) ?? SegmentTransition()
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
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
    /// The caption renders a bit smaller than the date stamp (≈22% smaller).
    static let captionFontScale: CGFloat = 0.78

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
