import Foundation

/// Whether a clip is a video file or a still photo.
enum ClipKind: String, Codable {
    case video, photo
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
    /// Path of the source-folder file this clip was picked from, if any.
    /// Several clips may share one source (and one copied media file), e.g.
    /// two segments cut from the same long video.
    var sourcePath: String? = nil

    var trimmedDuration: Double { max(0, outSeconds - inSeconds) }

    /// True when no tag filter is set, or the clip carries the tag
    /// (case-insensitive, matching how tags are deduped).
    func matches(tagFilter: String?) -> Bool {
        guard let tagFilter else { return true }
        return tags.contains { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, date, inSeconds, outSeconds, durationSeconds, createdAt,
             tags, kind, crop, showsDateOverlay, sourcePath
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
    let total = max(0, seconds)
    let m = Int(total) / 60
    let s = total.truncatingRemainder(dividingBy: 60)
    return String(format: "%d:%05.2f", m, s)
}
