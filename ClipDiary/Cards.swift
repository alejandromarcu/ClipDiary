import Foundation
import CoreGraphics
import AppKit
import SwiftUI

/// A designed title frame ("card"): a background colour plus stacked text and
/// image elements. Cards are saved per-project under `Cards/<id>/` (a `card.json`
/// document next to its copied image assets) and used three ways — as a video's
/// Cover, its Ending, or a clip on a specific day. Using a card **snapshots** it
/// to an image at that moment (see `LibraryStore.renderCardImage` / `addCard`),
/// so later edits don't retro-change already-placed clips.

// MARK: - Colour

/// A plain sRGB colour that survives JSON, with conversions to/from the
/// SwiftUI / AppKit / CoreGraphics colour types the UI and renderer need.
struct CardColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let black = CardColor(r: 0, g: 0, b: 0, a: 1)
    static let white = CardColor(r: 1, g: 1, b: 1, a: 1)

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Reads a SwiftUI `Color` back into sRGB components (for the colour pickers).
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

// MARK: - Text

/// Horizontal alignment of a text element, Codable in its own right (SwiftUI's
/// `TextAlignment` isn't).
enum CardTextAlignment: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

/// A text element's styling. `sizeFraction` is the font size as a fraction of
/// the canvas height so a card renders identically at any resolution.
struct TextStyle: Codable, Equatable, Hashable {
    var string: String
    var fontName: String
    var sizeFraction: Double
    var color: CardColor
    var alignment: CardTextAlignment
}

// MARK: - Elements

/// One thing drawn on a card: text or an image, positioned by a normalized,
/// top-left-origin frame (reusing `CropRect`). The element order in
/// `CardDocument.elements` is the z-order — index 0 is the backmost.
struct CardElement: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    /// Normalized frame (0…1) in the canvas, top-left origin — same convention
    /// as `CropRect` elsewhere, so the editor and renderer agree.
    var frame: CropRect
    var kind: Kind

    enum Kind: Codable, Equatable, Hashable {
        case text(TextStyle)
        /// File name of the image stored in the card's own folder.
        case image(assetID: String)
    }

    var isText: Bool { if case .text = kind { return true } else { return false } }
}

// MARK: - Document

/// A saved card. `aspect` records the canvas shape it was designed for (the
/// project's orientation at creation); if the project's orientation later
/// differs, the rendered card simply letterboxes like any photo.
struct CardDocument: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var background: CardColor = .black
    var aspect: ProjectSettings.Orientation
    var displaySeconds: Double = Card.defaultDisplaySeconds
    /// Back (index 0) to front.
    var elements: [CardElement] = []

    var canvasSize: CGSize { aspect.size }

    init(id: UUID = UUID(), name: String, background: CardColor = .black,
         aspect: ProjectSettings.Orientation,
         displaySeconds: Double = Card.defaultDisplaySeconds,
         elements: [CardElement] = []) {
        self.id = id
        self.name = name
        self.background = background
        self.aspect = aspect
        self.displaySeconds = displaySeconds
        self.elements = elements
    }

    enum CodingKeys: String, CodingKey {
        case id, name, background, aspect, displaySeconds, elements
    }

    /// Lenient decode (every optional field defaulted) so future card options
    /// need no migration — mirrors how `ProjectSettings` decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        background = try c.decodeIfPresent(CardColor.self, forKey: .background) ?? .black
        aspect = try c.decodeIfPresent(ProjectSettings.Orientation.self, forKey: .aspect) ?? .landscape
        displaySeconds = try c.decodeIfPresent(Double.self, forKey: .displaySeconds) ?? Card.defaultDisplaySeconds
        elements = try c.decodeIfPresent([CardElement].self, forKey: .elements) ?? []
    }
}

// MARK: - Constants / factory

/// Namespace for card defaults and the curated font list.
enum Card {
    /// Curated fonts the editor offers (label shown to the user → font family).
    static let fonts: [(label: String, name: String)] = [
        ("System", "Helvetica Neue"),
        ("Sans", "Avenir Next"),
        ("Serif", "Georgia"),
        ("Geometric", "Futura"),
        ("Script", "Snell Roundhand"),
        ("Mono", "Menlo"),
    ]

    static let defaultDisplaySeconds: Double = 3
    static let defaultTextSizeFraction: Double = 0.11

    static func newTextElement() -> CardElement {
        CardElement(
            frame: CropRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2),
            kind: .text(TextStyle(string: "Text", fontName: fonts[0].name,
                                  sizeFraction: defaultTextSizeFraction,
                                  color: .white, alignment: .center))
        )
    }

    /// A centered image element whose initial box matches the image's real
    /// aspect (so its resize handles feel natural), about half the canvas wide.
    static func newImageElement(assetID: String, imageSize: CGSize, canvas: CGSize) -> CardElement {
        var boxW = canvas.width * 0.5
        var boxH = imageSize.width > 0 ? boxW * imageSize.height / imageSize.width : boxW
        let maxH = canvas.height * 0.9
        if boxH > maxH { boxW *= maxH / boxH; boxH = maxH }
        let wN = min(1, boxW / canvas.width)
        let hN = min(1, boxH / canvas.height)
        return CardElement(
            frame: CropRect(x: (1 - wN) / 2, y: (1 - hN) / 2, width: wN, height: hN),
            kind: .image(assetID: assetID)
        )
    }
}

// MARK: - Renderer

/// Renders a card document to a flat image. Pure (assets passed in as already
/// loaded `CGImage`s), so it can run wherever the caller is. The editor canvas,
/// gallery thumbnails, day snapshots and cover/ending segments all go through
/// here, which keeps the editor WYSIWYG with the exported frame.
enum CardRenderer {
    /// Draws `doc` at `size`, with its image elements supplied in `assets`
    /// (keyed by `assetID`). Returns nil only if a bitmap context can't be made.
    static func drawCard(_ doc: CardDocument, assets: [String: CGImage], size: CGSize) -> CGImage? {
        let w = max(2, Int(size.width.rounded()))
        let h = max(2, Int(size.height.rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let W = CGFloat(w), H = CGFloat(h)

        // Background fills the whole canvas (orientation-agnostic).
        ctx.setFillColor(doc.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // Flip into a top-left origin so normalized frames map directly. Images
        // and text are then un-flipped locally as each needs.
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)

        func pixelRect(_ f: CropRect) -> CGRect {
            CGRect(x: f.x * W, y: f.y * H, width: f.width * W, height: f.height * H)
        }

        for element in doc.elements {
            let box = pixelRect(element.frame)
            switch element.kind {
            case .image(let assetID):
                guard let image = assets[assetID] else { continue }
                let fit = aspectFit(CGSize(width: image.width, height: image.height), in: box)
                // The CTM is y-down; flip locally so the image draws upright.
                ctx.saveGState()
                ctx.translateBy(x: fit.minX, y: fit.minY + fit.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: fit.width, height: fit.height))
                ctx.restoreGState()

            case .text(let style):
                let attributed = Self.attributedString(style, canvasHeight: H)
                let gctx = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gctx
                // Vertically center the text within its box (single titles look
                // better centered than pinned to the top).
                let bounds = attributed.boundingRect(
                    with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                let textH = min(box.height, ceil(bounds.height))
                let drawRect = CGRect(x: box.minX, y: box.minY + (box.height - textH) / 2,
                                      width: box.width, height: textH)
                attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        return ctx.makeImage()
    }

    /// The attributed string for a text element at a given canvas height,
    /// shared so the renderer is the single source of truth for text metrics.
    static func attributedString(_ style: TextStyle, canvasHeight: CGFloat) -> NSAttributedString {
        let size = max(1, style.sizeFraction * canvasHeight)
        let font = NSFont(name: style.fontName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment.nsTextAlignment
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: style.string, attributes: [
            .font: font,
            .foregroundColor: style.color.nsColor,
            .paragraphStyle: paragraph,
        ])
    }

    /// Largest rect of `imageSize`'s aspect that fits inside `box`, centered.
    private static func aspectFit(_ imageSize: CGSize, in box: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, box.width > 0, box.height > 0 else {
            return box
        }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Image helpers

extension CGImage {
    /// PNG-encodes the image (for snapshotting a card into `Clips/`).
    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }
}

extension NSImage {
    /// PNG-encodes a (pasted) image so it can be stored as a card asset.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
