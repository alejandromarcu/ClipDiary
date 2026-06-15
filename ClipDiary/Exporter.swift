import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import QuartzCore

enum ExportError: LocalizedError {
    case noClips
    case noVideoTrack(String)
    case sessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noClips: return "There are no clips to export."
        case .noVideoTrack(let name): return "No video track found in \(name)."
        case .sessionFailed(let reason): return "Export failed: \(reason)"
        }
    }
}

/// One stretch of the stitched timeline that shows a date stamp (and optional caption).
struct DateOverlay {
    let timeRange: CMTimeRange
    let text: String
    let caption: String
}

/// A stitched month ready to play or export. Photo clips live as rendered
/// MP4 segments in `tempDir`, so the composition is only valid until
/// `cleanUp()` is called — the previewer owns it while the player is open.
struct MonthComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    /// Volume ramp that fades the audio out at the end, or nil when the
    /// project has no ending fade. Both the export session and the preview
    /// player apply it (it can't be baked into the composition itself).
    let audioMix: AVMutableAudioMix?
    /// Date stamps for clips with the overlay enabled. The export burns
    /// them in via Core Animation; the preview window draws them itself
    /// (the animation tool only works with export sessions, not AVPlayer).
    let dateOverlays: [DateOverlay]
    /// The timeline stretch the ending fade covers (nil when disabled).
    /// The video fade is baked into the composition; this lets the export's
    /// date-stamp overlay and the preview's stamp fade in step with it.
    let fadeRange: CMTimeRange?
    let tempDir: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

struct Exporter {

    /// Stitches the trimmed clips (in order) into a single MP4 at `outputURL`.
    /// Every clip is aspect-fit into `renderSize` (letterboxed if needed).
    static func exportMovie(
        clips: [Clip],
        store: LibraryStore,
        outputURL: URL,
        renderSize: CGSize,
        fadeOutSeconds: Double? = nil,
        creationDate: Date? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let built = try await buildComposition(
            clips: clips, store: store, renderSize: renderSize, fadeOutSeconds: fadeOutSeconds
        )
        defer { built.cleanUp() }

        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality
        ) else { throw ExportError.sessionFailed("Could not create export session.") }

        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        if !built.dateOverlays.isEmpty {
            built.videoComposition.animationTool = makeDateOverlayTool(
                overlays: built.dateOverlays, renderSize: renderSize, fade: built.fadeRange
            )
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        if let creationDate { session.metadata = creationMetadata(for: creationDate) }

        // Poll progress while exporting.
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await session.export()
        poller.cancel()
        progress(1.0)

        if session.status != .completed {
            let reason = session.error?.localizedDescription ?? "Unknown error."
            throw ExportError.sessionFailed(reason)
        }

        // AVAssetExportSession stamps the movie/track header atoms with the
        // wall-clock export time, which is what tools (and Photos) report as
        // the "Create Date" — `session.metadata` can't override it. So rewrite
        // those atoms in the finished file to the requested capture date.
        if let creationDate { stampHeaderDates(in: outputURL, to: creationDate) }
    }

    /// Builds the month composition without exporting it, for in-app preview
    /// (the same composition the export path uses). The caller must call
    /// `cleanUp()` on the result when done with it.
    static func buildComposition(
        clips: [Clip],
        store: LibraryStore,
        renderSize: CGSize,
        fadeOutSeconds: Double? = nil
    ) async throws -> MonthComposition {
        guard !clips.isEmpty else { throw ExportError.noClips }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportError.sessionFailed("Could not create video track.") }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var overlays: [DateOverlay] = []
        var cursor = CMTime.zero
        // The last successfully inserted clip's layer + timeline range, so an
        // ending fade can ramp exactly that segment (never an earlier one).
        var lastLayer: AVMutableVideoCompositionLayerInstruction?
        var lastSegment: CMTimeRange?
        // Whether any clip contributed audio (an all-photos month has none, so
        // there's nothing for the ending fade's volume ramp to act on).
        var insertedAudio = false

        // Collect clip file URLs on the main actor before doing AV work.
        let items: [(clip: Clip, url: URL)] = await MainActor.run {
            clips.map { ($0, store.fileURL(for: $0)) }
        }

        // Photos are rendered into short video segments in a temp folder,
        // then stitched exactly like videos.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDiaryExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: tempDir) } }

        for (index, (clip, url)) in items.enumerated() {
            let assetURL: URL
            if clip.kind == .photo {
                assetURL = try await renderPhotoSegment(
                    clip: clip, photoURL: url, renderSize: renderSize,
                    in: tempDir, index: index
                )
            } else {
                assetURL = url
            }

            let asset = AVURLAsset(url: assetURL)
            guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.noVideoTrack(clip.fileName)
            }

            let range: CMTimeRange
            if clip.kind == .photo {
                // The rendered segment is exactly the chosen display duration.
                range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            } else {
                let inTime = CMTime(seconds: clip.inSeconds, preferredTimescale: 600)
                let outTime = CMTime(seconds: clip.outSeconds, preferredTimescale: 600)
                range = CMTimeRange(start: inTime, end: outTime)
            }
            guard range.duration > .zero else { continue }

            try videoTrack.insertTimeRange(range, of: srcVideo, at: cursor)

            if let audioTrack,
               let srcAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: srcAudio, at: cursor)
                insertedAudio = true
            }

            // Aspect-fit transform for this segment.
            let naturalSize = try await srcVideo.load(.naturalSize)
            let preferred = try await srcVideo.load(.preferredTransform)
            let orientedRect = CGRect(origin: .zero, size: naturalSize)
                .applying(preferred)
            let orientedSize = CGSize(width: abs(orientedRect.width),
                                      height: abs(orientedRect.height))

            let scale = min(renderSize.width / orientedSize.width,
                            renderSize.height / orientedSize.height)
            let scaledSize = CGSize(width: orientedSize.width * scale,
                                    height: orientedSize.height * scale)
            let tx = (renderSize.width - scaledSize.width) / 2 - orientedRect.minX * scale
            let ty = (renderSize.height - scaledSize.height) / 2 - orientedRect.minY * scale

            var transform = preferred
            transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(transform, at: cursor)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            lastLayer = layer
            lastSegment = instruction.timeRange

            if clip.showsDateOverlay || !clip.caption.isEmpty {
                overlays.append(DateOverlay(
                    timeRange: CMTimeRange(start: cursor, duration: range.duration),
                    text: clip.showsDateOverlay ? DateStamp.text(for: clip.date) : "",
                    caption: clip.caption
                ))
            }

            cursor = cursor + range.duration
        }

        guard cursor > .zero else { throw ExportError.noClips }
        let totalDuration = cursor

        // Optional ending fade to black: ramp the last clip's opacity (the
        // composition behind it is black) and its audio volume to zero over
        // the final stretch, clamped to that clip so earlier ones are untouched.
        var fadeRange: CMTimeRange?
        var audioMix: AVMutableAudioMix?
        if let fadeOutSeconds, fadeOutSeconds > 0,
           let lastLayer, let lastSegment {
            let fadeSeconds = min(fadeOutSeconds, lastSegment.duration.seconds)
            if fadeSeconds > 0 {
                let fadeDuration = CMTime(seconds: fadeSeconds, preferredTimescale: 600)
                let range = CMTimeRange(start: totalDuration - fadeDuration, duration: fadeDuration)
                lastLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
                if let audioTrack, insertedAudio {
                    let params = AVMutableAudioMixInputParameters(track: audioTrack)
                    params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range)
                    let mix = AVMutableAudioMix()
                    mix.inputParameters = [params]
                    audioMix = mix
                }
                fadeRange = range
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        succeeded = true
        return MonthComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            dateOverlays: overlays,
            fadeRange: fadeRange,
            tempDir: tempDir
        )
    }

    // MARK: - Metadata

    /// Metadata items stamping `date` as the movie's creation date, written in
    /// both the cross-format common space and the QuickTime space (the latter
    /// is what Finder/Photos surface as "Date Created" for an .mp4).
    private static func creationMetadata(for date: Date) -> [AVMetadataItem] {
        let iso = ISO8601DateFormatter().string(from: date)
        func item(_ identifier: AVMetadataIdentifier) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = iso as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        return [
            item(.commonIdentifierCreationDate),
            item(.quickTimeMetadataCreationDate),
        ]
    }

    /// Rewrites the creation/modification timestamps in the `mvhd`, `tkhd` and
    /// `mdhd` header atoms (the ones reported as "Create Date") to `date`. The
    /// wall-clock components of `date` are stored verbatim (QuickTime's 1904
    /// epoch, no timezone shift) so a reader shows the same local time the user
    /// chose, matching camera conventions. Best-effort: failures are ignored.
    private static func stampHeaderDates(in url: URL, to date: Date) {
        guard var data = try? Data(contentsOf: url) else { return }
        // QuickTime counts seconds from 1904-01-01; store the wall clock as-is
        // (treat the local time as if it were the stored epoch).
        let epochOffset: TimeInterval = 2_082_844_800
        let tzOffset = TimeInterval(TimeZone.current.secondsFromGMT(for: date))
        let seconds = UInt64(date.timeIntervalSince1970 + tzOffset + epochOffset)
        patchAtoms(&data, range: data.startIndex..<data.endIndex, seconds: seconds)
        try? data.write(to: url, options: .atomic)
    }

    /// Recursively walks the QuickTime atom tree in `range`, descending into
    /// the container atoms that hold headers and patching each header's dates.
    private static func patchAtoms(_ data: inout Data, range: Range<Int>, seconds: UInt64) {
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size32 = readUInt32(data, at: offset)
            let type = atomType(data, at: offset + 4)
            var headerSize = 8
            var atomSize = Int(size32)
            if size32 == 1 {                       // 64-bit extended size
                atomSize = Int(readUInt64(data, at: offset + 8))
                headerSize = 16
            } else if size32 == 0 {                // extends to end of parent
                atomSize = range.upperBound - offset
            }
            guard atomSize >= headerSize, offset + atomSize <= range.upperBound else { break }
            let body = offset + headerSize
            switch type {
            case "moov", "trak", "mdia":
                patchAtoms(&data, range: body..<(offset + atomSize), seconds: seconds)
            case "mvhd", "tkhd", "mdhd":
                patchHeaderDates(&data, at: body, seconds: seconds)
            default:
                break
            }
            offset += atomSize
        }
    }

    /// Patches creation + modification times in a `*hd` atom body, which begins
    /// with a 1-byte version (0 → 32-bit times, 1 → 64-bit) + 3 flag bytes.
    private static func patchHeaderDates(_ data: inout Data, at body: Int, seconds: UInt64) {
        guard body + 4 <= data.endIndex else { return }
        if data[body] == 1 {
            guard body + 4 + 16 <= data.endIndex else { return }
            writeUInt64(&data, at: body + 4, value: seconds)
            writeUInt64(&data, at: body + 12, value: seconds)
        } else {
            guard body + 4 + 8 <= data.endIndex else { return }
            let secs32 = UInt32(truncatingIfNeeded: seconds)
            writeUInt32(&data, at: body + 4, value: secs32)
            writeUInt32(&data, at: body + 8, value: secs32)
        }
    }

    private static func readUInt32(_ data: Data, at i: Int) -> UInt32 {
        (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private static func readUInt64(_ data: Data, at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(data[i + k]) }
        return v
    }

    private static func writeUInt32(_ data: inout Data, at i: Int, value: UInt32) {
        for k in 0..<4 { data[i + k] = UInt8((value >> (8 * (3 - k))) & 0xff) }
    }

    private static func writeUInt64(_ data: inout Data, at i: Int, value: UInt64) {
        for k in 0..<8 { data[i + k] = UInt8((value >> (8 * (7 - k))) & 0xff) }
    }

    private static func atomType(_ data: Data, at i: Int) -> String {
        String(bytes: data[i..<(i + 4)], encoding: .ascii) ?? ""
    }

    // MARK: - Date stamps

    /// Core Animation overlay that burns each clip's date stamp into the
    /// bottom-left corner during export, 1SE-style.
    private static func makeDateOverlayTool(
        overlays: [DateOverlay], renderSize: CGSize, fade: CMTimeRange?
    ) -> AVVideoCompositionCoreAnimationTool {
        let frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = frame
        let parentLayer = CALayer()
        parentLayer.frame = frame
        parentLayer.addSublayer(videoLayer)

        let base = min(renderSize.width, renderSize.height)
        let fontSize = base * DateStamp.fontFraction
        let leftMargin = base * DateStamp.leftMarginFraction
        let bottomMargin = base * DateStamp.bottomMarginFraction

        let lineHeight = fontSize * 1.4
        let lineGap = fontSize * 0.15

        for overlay in overlays {
            let beginTime = max(overlay.timeRange.start.seconds, AVCoreAnimationBeginTimeAtZero)
            let duration = overlay.timeRange.duration.seconds

            // If the ending fade overlaps this clip's segment (it only ever
            // does for the last one, being clamped to it), the fraction of the
            // segment at which the stamp should start fading to 0.
            var fadeFraction: Double?
            if let fade {
                let segStart = overlay.timeRange.start.seconds
                let segEnd = segStart + duration
                if fade.start.seconds < segEnd && fade.end.seconds > segStart {
                    let point = max(fade.start.seconds, segStart)
                    fadeFraction = min(max((point - segStart) / duration, 0), 1)
                }
            }

            func makeTextLayer(text: String, y: CGFloat) -> CATextLayer {
                let layer = CATextLayer()
                layer.string = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .kern: fontSize * DateStamp.trackingFraction,
                    .foregroundColor: NSColor.white,
                ])
                layer.alignmentMode = .left
                layer.contentsScale = 2
                // The animation tool's coordinate space has a bottom-left origin.
                layer.frame = CGRect(
                    x: leftMargin, y: y,
                    width: renderSize.width - leftMargin, height: lineHeight
                )
                layer.shadowColor = CGColor(gray: 0, alpha: 1)
                layer.shadowOpacity = 0.6
                layer.shadowRadius = fontSize * 0.06
                layer.shadowOffset = .zero

                // Visible only during the clip's segment: a frozen opacity
                // animation spans the time range (beginTime 0 means "now" to
                // Core Animation, hence AVCoreAnimationBeginTimeAtZero). When
                // the ending fade lands on this clip, hold at 1 until the fade
                // point, then ramp to 0 so the stamp dims with the picture.
                layer.opacity = 0
                let anim: CAPropertyAnimation
                if let fadeFraction {
                    let keyframe = CAKeyframeAnimation(keyPath: "opacity")
                    keyframe.values = [NSNumber(value: 1.0), NSNumber(value: 1.0), NSNumber(value: 0.0)]
                    keyframe.keyTimes = [NSNumber(value: 0.0), NSNumber(value: fadeFraction), NSNumber(value: 1.0)]
                    keyframe.calculationMode = .linear
                    anim = keyframe
                } else {
                    let basic = CABasicAnimation(keyPath: "opacity")
                    basic.fromValue = 1.0
                    basic.toValue = 1.0
                    anim = basic
                }
                anim.beginTime = beginTime
                anim.duration = duration
                anim.fillMode = .removed
                anim.isRemovedOnCompletion = false
                layer.add(anim, forKey: "visible")
                return layer
            }

            if !overlay.text.isEmpty {
                parentLayer.addSublayer(makeTextLayer(text: overlay.text, y: bottomMargin))
            }
            if !overlay.caption.isEmpty {
                let captionY = bottomMargin + lineHeight + lineGap
                parentLayer.addSublayer(makeTextLayer(text: overlay.caption, y: captionY))
            }
        }

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )
    }

    // MARK: - Photo segments

    /// Renders a photo clip (with its crop applied) into a silent MP4 of the
    /// clip's display duration, sized to fit within `renderSize`.
    private static func renderPhotoSegment(
        clip: Clip,
        photoURL: URL,
        renderSize: CGSize,
        in directory: URL,
        index: Int
    ) async throws -> URL {
        let maxPixel = Int(max(renderSize.width, renderSize.height)) * 2
        guard let oriented = loadOrientedCGImage(from: photoURL, maxPixel: maxPixel) else {
            throw ExportError.sessionFailed("Could not read photo \(clip.fileName).")
        }

        let image = clip.crop.map { croppedImage(oriented, to: $0) } ?? oriented

        // Even dimensions for H.264, never upscaled beyond the source.
        let fitScale = min(1, min(renderSize.width / CGFloat(image.width),
                                  renderSize.height / CGFloat(image.height)))
        let width = max(2, Int(CGFloat(image.width) * fitScale / 2) * 2)
        let height = max(2, Int(CGFloat(image.height) * fitScale / 2) * 2)

        let outputURL = directory.appendingPathComponent("photo-\(index).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)

        guard writer.startWriting() else {
            throw ExportError.sessionFailed(
                writer.error?.localizedDescription ?? "Could not write photo segment."
            )
        }
        writer.startSession(atSourceTime: .zero)

        let duration = CMTime(seconds: max(0.5, clip.trimmedDuration), preferredTimescale: 600)
        let frameDuration = CMTime(value: 1, timescale: 30)
        var times = [CMTime.zero]
        let lastFrame = duration - frameDuration
        if lastFrame > .zero { times.append(lastFrame) }

        for time in times {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = makePixelBuffer(from: image, pool: pool,
                                               width: width, height: height) else {
                throw ExportError.sessionFailed("Could not render photo \(clip.fileName).")
            }
            adaptor.append(buffer, withPresentationTime: time)
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.sessionFailed(
                writer.error?.localizedDescription ?? "Could not write photo segment."
            )
        }
        return outputURL
    }

    private static func makePixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return buffer
    }
}
