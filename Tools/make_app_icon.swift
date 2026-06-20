// Generates the ClipDiary app icon (a filmstrip + play button on a sunset
// gradient) at every macOS size, drawing each natively with CoreGraphics so it
// stays crisp at 16px. No third-party dependencies.
//
//   Regenerate the asset catalog icons:
//     swift Tools/make_app_icon.swift ClipDiary/Assets.xcassets/AppIcon.appiconset
//
//   Render a single preview size (e.g. 512) into a scratch dir:
//     swift Tools/make_app_icon.swift /tmp/icon-out 512
//
// (The 10 PNGs it writes are committed; this script is the editable source.)

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ---- helpers --------------------------------------------------------------

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

func roundedRectPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// rounded polygon via tangent arcs
func roundedPolyPath(_ pts: [CGPoint], _ radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let n = pts.count
    let mid = CGPoint(x: (pts[n-1].x + pts[0].x)/2, y: (pts[n-1].y + pts[0].y)/2)
    p.move(to: mid)
    for i in 0..<n {
        p.addArc(tangent1End: pts[i], tangent2End: pts[(i+1) % n], radius: radius)
    }
    p.closeSubpath()
    return p
}

// ---- the icon -------------------------------------------------------------

func drawIcon(_ ctx: CGContext, _ S: CGFloat) {
    let cs = CGColorSpaceCreateDeviceRGB()

    // squircle geometry (Apple macOS grid: 824/1024 art, ~185/1024 corner)
    let inset  = S * 100.0/1024.0
    let side   = S - inset*2
    let corner = S * 185.0/1024.0
    let box    = CGRect(x: inset, y: inset, width: side, height: side)
    let squircle = roundedRectPath(box, corner)

    // soft drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.010),
                  blur: S*0.028, color: rgb(0,0,0,0.28))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(255,255,255,1))
    ctx.fillPath()
    ctx.restoreGState()

    // clip everything else to the tile
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // sunset gradient background (top-left warm -> bottom-right violet)
    let grad = CGGradient(colorsSpace: cs,
        colors: [rgb(255,153,102), rgb(255,94,138), rgb(124,58,237)] as CFArray,
        locations: [0.0, 0.52, 1.0])!
    ctx.drawLinearGradient(grad,
        start: CGPoint(x: box.minX, y: box.maxY),
        end:   CGPoint(x: box.maxX, y: box.minY),
        options: [])

    // glossy highlight near the top
    let glow = CGGradient(colorsSpace: cs,
        colors: [rgb(255,255,255,0.26), rgb(255,255,255,0.0)] as CFArray,
        locations: [0.0, 1.0])!
    ctx.drawRadialGradient(glow,
        startCenter: CGPoint(x: box.midX, y: box.minY + side*0.80), startRadius: 0,
        endCenter:   CGPoint(x: box.midX, y: box.minY + side*0.80), endRadius: side*0.62,
        options: [])

    // --- filmstrip bands (top + bottom) with perforations ---
    let bandH = side * 0.135
    let bands = [CGRect(x: box.minX, y: box.maxY - bandH, width: side, height: bandH),
                 CGRect(x: box.minX, y: box.minY,         width: side, height: bandH)]
    for band in bands {
        ctx.addRect(band)
        ctx.setFillColor(rgb(20, 12, 30, 0.30))
        ctx.fillPath()
        // perforations
        let holes = 6
        let hole  = side * 0.052
        let r     = hole * 0.32
        let gap   = (side - CGFloat(holes) * hole) / CGFloat(holes + 1)
        let hy    = band.midY - hole/2
        for i in 0..<holes {
            let hx = box.minX + gap + CGFloat(i) * (hole + gap)
            ctx.addPath(roundedRectPath(CGRect(x: hx, y: hy, width: hole, height: hole), r))
        }
        ctx.setFillColor(rgb(255,255,255,0.92))
        ctx.fillPath()
    }

    // --- play triangle (white, rounded) ---
    let cx = box.midX, cy = box.midY
    let w  = side * 0.30
    let h  = side * 0.34
    let shift = w/6        // optical centering
    let pts = [
        CGPoint(x: cx - w/2 + shift, y: cy + h/2),
        CGPoint(x: cx - w/2 + shift, y: cy - h/2),
        CGPoint(x: cx + w/2 + shift, y: cy),
    ]
    let tri = roundedPolyPath(pts, side*0.045)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.006),
                  blur: S*0.018, color: rgb(40,10,40,0.30))
    ctx.addPath(tri)
    ctx.setFillColor(rgb(255,255,255,1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()
}

// ---- render ---------------------------------------------------------------

func writePNG(_ size: Int, _ url: URL) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(ctx, CGFloat(size))
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "/tmp/clipicon/out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// preview only if a single size passed as arg 2
if args.count > 2, let s = Int(args[2]) {
    writePNG(s, URL(fileURLWithPath: "\(outDir)/preview_\(s).png"))
    print("wrote preview_\(s).png")
} else {
    let slots: [(String, Int)] = [
        ("icon_16x16",     16), ("icon_16x16@2x",  32),
        ("icon_32x32",     32), ("icon_32x32@2x",  64),
        ("icon_128x128",  128), ("icon_128x128@2x",256),
        ("icon_256x256",  256), ("icon_256x256@2x",512),
        ("icon_512x512",  512), ("icon_512x512@2x",1024),
    ]
    for (name, px) in slots {
        writePNG(px, URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
    print("wrote \(slots.count) icons to \(outDir)")
}
