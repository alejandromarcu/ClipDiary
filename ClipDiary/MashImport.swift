import SwiftUI
import AVFoundation
import Vision
import UniformTypeIdentifiers

/// Importing a "mashed" 1SE export: 1 Second Everyday burns the date into
/// the bottom-left corner of every frame, so we OCR that stamp, split the
/// video where the date changes, and register one clip per day.

/// A stretch of the source video that belongs to one calendar day.
struct MashDaySegment: Identifiable {
    let id = UUID()
    /// Day key parsed from the burned-in stamp.
    let date: Date
    let start: Double
    let end: Double
    var duration: Double { end - start }
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
        return zip(runs, zip(starts, ends)).map { run, range in
            MashDaySegment(date: run.date, start: range.0, end: range.1)
        }
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
        case review([MashDaySegment])
        case importing(done: Int, total: Int)
        case failed(String)
    }
    @State private var phase: Phase = .scanning(0)

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

            case .review(let segments):
                Text("Found \(segments.count) days. Each becomes its own clip on its calendar day.")
                List(segments) { segment in
                    HStack {
                        Text(segment.date.formatted(.dateTime.year().month().day()))
                        Spacer()
                        Text(formatTime(segment.duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 240)

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
                if case .review(let segments) = phase {
                    Button("Import \(segments.count) Days") {
                        runImport(segments)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .task { await scan() }
    }

    private var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    private func scan() async {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let url = sourceURL
            let segments = try await MashImporter.scan(url: url) { value in
                Task { @MainActor in
                    if case .scanning = phase { phase = .scanning(value) }
                }
            }
            phase = .review(segments)
        } catch is CancellationError {
            // Sheet was dismissed mid-scan.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func runImport(_ segments: [MashDaySegment]) {
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
