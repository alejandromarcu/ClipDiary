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

/// One stretch of the stitched timeline that shows a date stamp.
struct DateOverlay {
    let timeRange: CMTimeRange
    let text: String
}

/// A stitched month ready to play or export. Photo clips live as rendered
/// MP4 segments in `tempDir`, so the composition is only valid until
/// `cleanUp()` is called — the previewer owns it while the player is open.
struct MonthComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    /// Date stamps for clips with the overlay enabled. The export burns
    /// them in via Core Animation; the preview window draws them itself
    /// (the animation tool only works with export sessions, not AVPlayer).
    let dateOverlays: [DateOverlay]
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
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let built = try await buildComposition(clips: clips, store: store, renderSize: renderSize)
        defer { built.cleanUp() }

        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality
        ) else { throw ExportError.sessionFailed("Could not create export session.") }

        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        if !built.dateOverlays.isEmpty {
            built.videoComposition.animationTool = makeDateOverlayTool(
                overlays: built.dateOverlays, renderSize: renderSize
            )
        }
        session.videoComposition = built.videoComposition

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
    }

    /// Builds the month composition without exporting it, for in-app preview
    /// (the same composition the export path uses). The caller must call
    /// `cleanUp()` on the result when done with it.
    static func buildComposition(
        clips: [Clip],
        store: LibraryStore,
        renderSize: CGSize
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

            if clip.showsDateOverlay {
                overlays.append(DateOverlay(
                    timeRange: CMTimeRange(start: cursor, duration: range.duration),
                    text: DateStamp.text(for: clip.date)
                ))
            }

            cursor = cursor + range.duration
        }

        guard cursor > .zero else { throw ExportError.noClips }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        succeeded = true
        return MonthComposition(
            composition: composition,
            videoComposition: videoComposition,
            dateOverlays: overlays,
            tempDir: tempDir
        )
    }

    // MARK: - Date stamps

    /// Core Animation overlay that burns each clip's date stamp into the
    /// bottom-left corner during export, 1SE-style.
    private static func makeDateOverlayTool(
        overlays: [DateOverlay], renderSize: CGSize
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

        for overlay in overlays {
            let layer = CATextLayer()
            layer.string = NSAttributedString(string: overlay.text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .kern: fontSize * DateStamp.trackingFraction,
                .foregroundColor: NSColor.white,
            ])
            layer.alignmentMode = .left
            layer.contentsScale = 2
            // The animation tool's coordinate space has a bottom-left origin.
            layer.frame = CGRect(
                x: leftMargin, y: bottomMargin,
                width: renderSize.width - leftMargin, height: fontSize * 1.4
            )
            layer.shadowColor = CGColor(gray: 0, alpha: 1)
            layer.shadowOpacity = 0.6
            layer.shadowRadius = fontSize * 0.06
            layer.shadowOffset = .zero

            // Visible only during the clip's segment: a frozen opacity
            // animation spans the time range (beginTime 0 means "now" to
            // Core Animation, hence AVCoreAnimationBeginTimeAtZero).
            layer.opacity = 0
            let visible = CABasicAnimation(keyPath: "opacity")
            visible.fromValue = 1.0
            visible.toValue = 1.0
            visible.beginTime = max(overlay.timeRange.start.seconds,
                                    AVCoreAnimationBeginTimeAtZero)
            visible.duration = overlay.timeRange.duration.seconds
            visible.fillMode = .removed
            visible.isRemovedOnCompletion = false
            layer.add(visible, forKey: "visible")

            parentLayer.addSublayer(layer)
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

        var image = oriented
        if let crop = clip.crop, !crop.isFull {
            let pixelRect = CGRect(
                x: crop.x * Double(oriented.width),
                y: crop.y * Double(oriented.height),
                width: crop.width * Double(oriented.width),
                height: crop.height * Double(oriented.height)
            ).integral
            if let cropped = oriented.cropping(to: pixelRect) {
                image = cropped
            }
        }

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
