import SwiftUI
import AppKit
import AVFoundation
import Vision
import UniformTypeIdentifiers

/// Importing a "mashed" 1SE export: 1 Second Everyday burns the date into
/// the bottom-left corner of every frame, so we OCR that stamp, split the
/// video where the date changes, and register one clip per day.

/// How a day's date came to be, surfaced in the review list.
enum MashDateFlag {
    /// The OCR'd date fit the chronological order; taken as-is.
    case ok
    /// The OCR'd date broke the order (a misread) and was snapped back onto
    /// the day it was embedded in. Highlighted so the user can double-check.
    case corrected
    /// The date broke the order but couldn't be placed automatically; the
    /// user must set it.
    case needsReview
}

/// A stretch of the source video that belongs to one calendar day.
struct MashDaySegment: Identifiable {
    let id: UUID
    /// Day key (the user can correct it in review, so it is mutable).
    var date: Date
    var start: Double
    var end: Double
    var flag: MashDateFlag
    /// The day(s) the burned-in stamp was actually read as before any
    /// correction/merge — shown as "read as …" so a fix is verifiable.
    var originalDates: [Date]
    var duration: Double { end - start }

    init(id: UUID = UUID(), date: Date, start: Double, end: Double,
         flag: MashDateFlag = .ok, originalDates: [Date]? = nil) {
        self.id = id
        self.date = date
        self.start = start
        self.end = end
        self.flag = flag
        self.originalDates = originalDates ?? [date]
    }
}

enum MashImportError: LocalizedError {
    case noStampsFound
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noStampsFound:
            return "No 1SE date stamps were found in the bottom-left corner. "
                + "Is this a 1 Second Everyday export with the date overlay enabled?"
        case .exportFailed(let reason):
            return "Could not write a day's segment: \(reason)"
        }
    }
}

enum MashImporter {
    /// Seconds between samples in the first pass. 1SE snippets are usually
    /// at least a second long, so this cannot skip over a whole day.
    private static let coarseStep = 0.3
    /// Boundaries are refined down to about one frame.
    private static let refineTolerance = 1.0 / 30

    // MARK: - Scanning

    /// OCRs the date stamp across the video and returns one segment per
    /// run of consecutive identical dates. `progress` is called on an
    /// arbitrary thread with values in 0...1.
    static func scan(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [MashDaySegment] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = makeGenerator(for: asset)

        // Coarse pass: sample at fixed intervals. Unreadable samples (clip
        // cross-fades blend two frames) are simply skipped; a wrong-but-
        // parseable date cannot survive the run-collapsing below unless the
        // same misread happens twice in a row, which we've never observed.
        var runs: [(date: Date, first: Double, last: Double)] = []
        var t = 0.0
        while t < duration {
            try Task.checkCancellation()
            if let date = await stampDate(at: t, generator: generator) {
                if let last = runs.last, last.date == date {
                    runs[runs.count - 1].last = t
                } else {
                    runs.append((date, t, t))
                }
            }
            t += coarseStep
            progress(min(t / duration, 1))
        }
        guard !runs.isEmpty else { throw MashImportError.noStampsFound }

        // Refine each day boundary by bisection between the last sample of
        // one date and the first sample of the next. During a cross-fade
        // the stamp is unreadable; those frames go to the newer day.
        var boundaries: [Double] = []
        for i in 1..<runs.count {
            try Task.checkCancellation()
            var lo = runs[i - 1].last
            var hi = runs[i].first
            while hi - lo > refineTolerance {
                let mid = (lo + hi) / 2
                if await stampDate(at: mid, generator: generator) == runs[i - 1].date {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            boundaries.append(hi)
        }

        // The video may open/close with stretches that carry no stamp
        // (title card, 1SE outro); keep a small margin past the outermost
        // readable samples instead of gluing those stretches to a day.
        let first = max(0, runs.first!.first - coarseStep)
        let last = min(duration, runs.last!.last + coarseStep)
        let starts = [first] + boundaries
        let ends = boundaries + [last]
        let segments = zip(runs, zip(starts, ends)).map { run, range in
            MashDaySegment(date: run.date, start: range.0, end: range.1)
        }
        return resolveDates(segments)
    }

    // MARK: - Anomaly detection & correction

    /// Cleans the raw per-run segments into a chronologically consistent day
    /// list. A 1SE mashup plays its days strictly in order, so any date that
    /// breaks that order is an OCR misread — typically a busy background making
    /// the burned-in stamp briefly unreadable, which produces a wrong date or
    /// even splits one real day into several pieces. Each misread is snapped
    /// back onto the day it sits inside, then same-day pieces are merged so the
    /// day plays as one clip instead of a hard cut mid-action.
    static func resolveDates(_ segments: [MashDaySegment]) -> [MashDaySegment] {
        var segs = segments
        let trusted = longestNonDecreasingSubsequence(segs.map(\.date))

        // Walk each maximal run of out-of-order ("untrusted") segments and snap
        // it onto the day it belongs to (see `snapTarget`); runs we can't place
        // confidently are flagged for the user.
        var i = 0
        while i < segs.count {
            if trusted.contains(i) { i += 1; continue }
            let start = i
            while i < segs.count && !trusted.contains(i) { i += 1 }
            let end = i - 1
            let before = start > 0 ? segs[start - 1].date : nil
            let after = end + 1 < segs.count ? segs[end + 1].date : nil
            let runDates = (start...end).map { segs[$0].date }
            let snap = snapTarget(runDates, before: before, after: after)
            for k in start...end {
                if let snap {
                    segs[k].date = snap
                    segs[k].flag = .corrected
                } else {
                    segs[k].flag = .needsReview
                }
            }
        }
        return mergeAdjacentSameDay(segs)
    }

    /// The day an out-of-order run should snap to, given the trusted days
    /// bracketing it (`before`/`after`, nil at the video's start/end):
    /// - bracketed by the *same* day → the run sits inside that day (the common
    ///   case, a stamp misread mid-clip);
    /// - bracketed by *different* days → it straddles a boundary, but if the
    ///   misread still got the month and day right and only the year wrong (a
    ///   common OCR slip, e.g. "FEB 08 2045" for 2025) snap to the neighbour
    ///   sharing that month/day;
    /// - only one neighbour (run at an edge) → that neighbour;
    /// - otherwise genuinely ambiguous → nil, left for the user.
    private static func snapTarget(_ runDates: [Date], before: Date?, after: Date?) -> Date? {
        switch (before, after) {
        case let (b?, a?):
            if b == a { return b }
            if runDates.allSatisfy({ sameMonthDay($0, b) }) { return b }
            if runDates.allSatisfy({ sameMonthDay($0, a) }) { return a }
            return nil
        case let (b?, nil): return b
        case let (nil, a?): return a
        case (nil, nil): return nil
        }
    }

    /// Same calendar month and day, ignoring the year.
    private static func sameMonthDay(_ a: Date, _ b: Date) -> Bool {
        let cal = Calendar.current
        return cal.component(.month, from: a) == cal.component(.month, from: b)
            && cal.component(.day, from: a) == cal.component(.day, from: b)
    }

    /// Indices of one longest *non-decreasing* subsequence of `dates` (O(n²),
    /// fine for the at-most-a-year of days in a mashup). These are the dates
    /// consistent with chronological order; the rest are the misreads. Equal
    /// dates are allowed in the run because a single day legitimately appears
    /// as several pieces when a misread split it — both correct reads must stay
    /// trusted, otherwise the second one would be flagged as the anomaly.
    static func longestNonDecreasingSubsequence(_ dates: [Date]) -> Set<Int> {
        let n = dates.count
        guard n > 0 else { return [] }
        var length = [Int](repeating: 1, count: n)   // longest run ending at i
        var prev = [Int](repeating: -1, count: n)    // predecessor in that run
        var best = 0
        for i in 0..<n {
            for j in 0..<i where dates[j] <= dates[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                prev[i] = j
            }
            if length[i] > length[best] { best = i }
        }
        var result = Set<Int>()
        var k = best
        while k != -1 {
            result.insert(k)
            k = prev[k]
        }
        return result
    }

    /// Collapses runs of adjacent segments that share a calendar day into one
    /// contiguous segment, carrying the most-severe flag and all the dates the
    /// pieces were originally read as.
    static func mergeAdjacentSameDay(_ segments: [MashDaySegment]) -> [MashDaySegment] {
        var result: [MashDaySegment] = []
        for seg in segments {
            if var last = result.last, last.date == seg.date {
                last.end = seg.end
                last.originalDates += seg.originalDates
                last.flag = moreSevere(last.flag, seg.flag)
                result[result.count - 1] = last
            } else {
                result.append(seg)
            }
        }
        return result
    }

    private static func moreSevere(_ a: MashDateFlag, _ b: MashDateFlag) -> MashDateFlag {
        if a == .needsReview || b == .needsReview { return .needsReview }
        if a == .corrected || b == .corrected { return .corrected }
        return .ok
    }

    private static func makeGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    private static func stampDate(
        at seconds: Double, generator: AVAssetImageGenerator
    ) async -> Date? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return recognizeStamp(in: result.image)
    }

    private static func recognizeStamp(in image: CGImage) -> Date? {
        // The stamp sits in the bottom-left; cropping cuts OCR cost and
        // avoids false hits from text elsewhere in the scene.
        let cropRect = CGRect(
            x: 0, y: Int(Double(image.height) * 0.75),
            width: Int(Double(image.width) * 0.40),
            height: image.height - Int(Double(image.height) * 0.75)
        )
        guard let cropped = image.cropping(to: cropRect) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return nil }

        // Vision often splits the stamp into separate observations
        // ("MAR 01" + "2026"); join them left-to-right before parsing.
        let joined = observations
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        return parseStamp(joined)
    }

    private static let monthNumbers: [Substring: Int] = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
        "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
    ]

    /// Parses e.g. "MAR 03 2026". Vision sometimes drops the space after
    /// the month ("MAR29"), so that separator is optional.
    static func parseStamp(_ text: String) -> Date? {
        let pattern = #/([A-Z]{3})\s*(\d{1,2})\s+(\d{4})/#
        guard let match = text.uppercased().firstMatch(of: pattern),
              let month = monthNumbers[match.1],
              let day = Int(match.2), (1...31).contains(day),
              let year = Int(match.3), (2000...2100).contains(year)
        else { return nil }
        let components = DateComponents(
            calendar: Calendar.current, year: year, month: month, day: day
        )
        guard let date = components.date, components.isValidDate else { return nil }
        return date.dayKey
    }

    // MARK: - Splitting

    /// Re-encodes one day's range into its own MP4. Re-encoding (rather
    /// than passthrough) keeps the cuts frame-accurate; the source is a
    /// 1SE export and already a compressed generation, so the loss is moot.
    static func exportSegment(
        of url: URL, segment: MashDaySegment, to outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw MashImportError.exportFailed("could not create export session")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: segment.start, preferredTimescale: 600),
            end: CMTime(seconds: segment.end, preferredTimescale: 600)
        )
        await session.export()
        if session.status != .completed {
            throw MashImportError.exportFailed(
                session.error?.localizedDescription ?? "unknown error"
            )
        }
    }
}

// MARK: - Import sheet

/// Scans a 1SE export, shows the detected days for review, then splits the
/// video and adds one clip per day to the library.
struct MashImportSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let sourceURL: URL

    private enum Phase {
        case scanning(Double)
        case review
        case importing(done: Int, total: Int)
        case failed(String)
    }
    @State private var phase: Phase = .scanning(0)
    /// The detected days, mutated in place as the user corrects flagged dates.
    @State private var segments: [MashDaySegment] = []
    /// A frame from the middle of each segment, keyed by segment id, so the
    /// user can read the real burned-in date when a stamp was misread.
    @State private var thumbnails: [UUID: NSImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import 1SE Video")
                .font(.title3.bold())
            Text(sourceURL.lastPathComponent)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            switch phase {
            case .scanning(let progress):
                ProgressView(value: progress) {
                    Text("Reading date stamps… \(Int(progress * 100))%")
                }

            case .review:
                reviewContent

            case .importing(let done, let total):
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("Splitting day \(min(done + 1, total)) of \(total)…")
                }

            case .failed(let message):
                Text(message).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isImporting)
                if case .review = phase {
                    Button("Import \(segments.count) Days") {
                        runImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(segments.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        // Esc would otherwise close the sheet mid-import, leaving the
        // splitting task running invisibly (Cancel is already disabled).
        .interactiveDismissDisabled(isImporting)
        .task { await scan() }
    }

    private var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    private var correctedCount: Int {
        segments.filter { if case .corrected = $0.flag { return true }; return false }.count
    }
    private var needsReviewCount: Int {
        segments.filter { if case .needsReview = $0.flag { return true }; return false }.count
    }

    @ViewBuilder
    private var reviewContent: some View {
        Text("Found \(segments.count) days. Each becomes its own clip on its calendar day.")
        if correctedCount > 0 {
            Label(
                "Auto-corrected \(correctedCount) misread date\(correctedCount == 1 ? "" : "s") "
                    + "(out of order in a 1SE export). They're highlighted below — "
                    + "check the frame and adjust if any look wrong.",
                systemImage: "wand.and.stars"
            )
            .font(.callout)
            .foregroundStyle(.blue)
            .fixedSize(horizontal: false, vertical: true)
        }
        if needsReviewCount > 0 {
            Label(
                "\(needsReviewCount) date\(needsReviewCount == 1 ? "" : "s") couldn't be "
                    + "placed automatically — set the correct date on the orange rows.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        List {
            ForEach(segments) { segment in
                reviewRow(segment)
            }
        }
        .frame(height: 320)
    }

    @ViewBuilder
    private func reviewRow(_ segment: MashDaySegment) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: segment)
            VStack(alignment: .leading, spacing: 4) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { segment.date },
                        set: { setDate($0, forID: segment.id) }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                if let note = note(for: segment) {
                    Label(note.text, systemImage: note.icon)
                        .font(.caption)
                        .foregroundStyle(note.color)
                }
            }
            Spacer()
            Text(formatTime(segment.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .listRowBackground(rowBackground(for: segment))
    }

    private func rowBackground(for segment: MashDaySegment) -> Color? {
        switch segment.flag {
        case .ok: return nil
        case .corrected: return Color.blue.opacity(0.10)
        case .needsReview: return Color.orange.opacity(0.14)
        }
    }

    /// The "read as …" / "set the date" caption under a corrected or
    /// out-of-order day. Returns nil for days whose stamp read cleanly.
    private func note(for segment: MashDaySegment) -> (text: String, icon: String, color: Color)? {
        switch segment.flag {
        case .ok:
            return nil
        case .corrected:
            let misreads = segment.originalDates
                .filter { $0 != segment.date }
                .map { $0.formatted(.dateTime.month(.abbreviated).day().year()) }
            let unique = NSOrderedSet(array: misreads).array as? [String] ?? []
            let detail = unique.isEmpty ? "" : " — read as \(unique.joined(separator: ", "))"
            return ("Auto-corrected\(detail)", "wand.and.stars", .blue)
        case .needsReview:
            return ("Out of order — set the correct date", "exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder
    private func thumbnail(for segment: MashDaySegment) -> some View {
        let size = CGSize(width: 200, height: 112)
        if let image = thumbnails[segment.id] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(width: size.width, height: size.height)
                .overlay(ProgressView().controlSize(.small))
        }
    }

    private func scan() async {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let url = sourceURL
            let scanned = try await MashImporter.scan(url: url) { value in
                Task { @MainActor in
                    if case .scanning = phase { phase = .scanning(value) }
                }
            }
            segments = scanned   // already cleaned/merged by resolveDates
            phase = .review
            // Generated after showing the list so rows appear immediately and
            // fill in their frames; access stays scoped until this returns.
            await loadThumbnails(for: segments)
        } catch is CancellationError {
            // Sheet was dismissed mid-scan.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Grabs a frame from the middle of each segment for the review list.
    private func loadThumbnails(for segs: [MashDaySegment]) async {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Large enough that the bottom-left date stamp stays legible when the
        // user is checking a flagged frame.
        generator.maximumSize = CGSize(width: 640, height: 640)
        for seg in segs {
            if Task.isCancelled { return }
            let mid = (seg.start + seg.end) / 2
            let time = CMTime(seconds: mid, preferredTimescale: 600)
            if let (cg, _) = try? await generator.image(at: time) {
                thumbnails[seg.id] = NSImage(cgImage: cg, size: .zero)
            }
        }
    }

    /// Applies a user's manual date correction and re-merges: in a 1SE mashup,
    /// adjacent segments that now share a day are the same physical day. The
    /// edit is taken as authoritative, so the row's flag clears.
    private func setDate(_ newDate: Date, forID id: UUID) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].date = newDate.dayKey
        segments[i].flag = .ok
        segments = MashImporter.mergeAdjacentSameDay(segments)
    }

    private func runImport() {
        let segments = self.segments
        phase = .importing(done: 0, total: segments.count)
        Task {
            let didStart = sourceURL.startAccessingSecurityScopedResource()
            defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                for (i, segment) in segments.enumerated() {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".mp4")
                    try await MashImporter.exportSegment(
                        of: sourceURL, segment: segment, to: tempURL
                    )
                    await store.adoptVideo(at: tempURL, date: segment.date,
                                           showsDateOverlay: false)
                    phase = .importing(done: i + 1, total: segments.count)
                }
                dismiss()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
