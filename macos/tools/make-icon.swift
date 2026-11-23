// Draws the app icon into an .iconset.
// The picture: two chain links on a dark graphite tile. The portrait link is the phone (violet to orange),
// the landscape link is the Mac (white to silver). The phone link is on top at the upper crossing,
// the Mac link is on top at the lower crossing.
// The tile follows the macOS icon grid: an 824 pt squircle in a 1024 pt canvas.
// Run: swift tools/make-icon.swift <output.iconset>
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: Tunables. Canvas units: 1024 x 1024, origin top left, y down.

typealias Stops = [(UInt32, CGFloat, CGFloat)]    // Color, alpha, location.

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185
let tileShadow = (alpha: 0.28 as CGFloat, blur: 20 as CGFloat, dy: 10 as CGFloat)
let tileStops: Stops = [(0x34363F, 1, 0), (0x1B1C22, 1, 0.55), (0x0E0F13, 1, 1)]
let glow = (hex: 0x6A4DFF as UInt32, alpha: 0.26 as CGFloat, center: CGPoint(x: 512, y: 500), radius: 0.52 as CGFloat)  // Radius is a fraction of the tile width.
let rimAlpha: CGFloat = 0.18                     // The light line on the top edge of the tile.

let phoneStops: Stops = [(0x8467FF, 1, 0), (0xDE4BD6, 1, 0.5), (0xFF9254, 1, 1)]
let macStops: Stops = [(0xFFFFFF, 1, 0), (0xC9CEDB, 1, 1)]
let glyphShadow = (alpha: 0.35 as CGFloat, blur: 24 as CGFloat, dy: 10 as CGFloat)  // Only at 128 px and larger.

// The outer corner radius is the same for both links, so the inner corners are concentric and have the same radius too.
struct LinkSpec {
    let phone, mac: CGRect
    let stroke, radius, gap: CGFloat
}

// The small sizes put all the main edges on whole device pixels.
func linkSpec(_ px: Int) -> LinkSpec {
    switch px {
    case ...16:   // 64 units for each pixel. Strokes are 1 px. No gap: the top link covers the other one.
        return LinkSpec(phone: CGRect(x: 192, y: 192, width: 320, height: 640), mac: CGRect(x: 320, y: 320, width: 512, height: 384),
                        stroke: 64, radius: 72, gap: 0)
    case ...32:   // 32 units for each pixel. Strokes are 2 px, gaps are 1 px.
        return LinkSpec(phone: CGRect(x: 192, y: 224, width: 320, height: 576), mac: CGRect(x: 320, y: 320, width: 512, height: 384),
                        stroke: 64, radius: 96, gap: 32)
    case ...64:   // 16 units for each pixel. Strokes are 4 px, gaps are 1 px.
        return LinkSpec(phone: CGRect(x: 240, y: 240, width: 288, height: 544), mac: CGRect(x: 352, y: 368, width: 432, height: 288),
                        stroke: 64, radius: 96, gap: 16)
    default:      // The phone is 3 strokes and 2 clear spaces wide, so the Mac link has the same space on its two sides.
        let w: CGFloat = 62, clear: CGFloat = 56
        let pw = 3 * w + 2 * clear, mw: CGFloat = 440
        let x0 = 512 - (w + clear + mw) / 2
        return LinkSpec(phone: CGRect(x: x0, y: 242, width: pw, height: 540), mac: CGRect(x: x0 + w + clear, y: 372, width: mw, height: 280),
                        stroke: w, radius: 92, gap: 16)
    }
}

// MARK: Drawing.

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                           CGFloat(hex & 255) / 255, a])!
}

func gradient(_ stops: Stops) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    Path(roundedRect: r, cornerRadius: radius, style: .continuous).cgPath
}

// A ring is the outer shape minus the hole. Use the even-odd rule to fill it.
func ring(_ r: CGRect, _ radius: CGFloat, _ w: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
    p.addRoundedRect(in: r.insetBy(dx: w, dy: w), cornerWidth: radius - w, cornerHeight: radius - w)
    return p
}

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    let all: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

    // Shadow sizes are in canvas units. Core Graphics wants device pixels, y up.
    func setShadow(_ sh: (alpha: CGFloat, blur: CGFloat, dy: CGFloat)) {
        ctx.setShadow(offset: CGSize(width: 0, height: -sh.dy * s), blur: sh.blur * s, color: color(0, sh.alpha))
    }
    func fill(_ path: CGPath, _ c: CGColor, evenOdd: Bool = false) {
        ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
    }
    func vertical(_ stops: Stops, _ box: CGRect) {
        ctx.drawLinearGradient(gradient(stops), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: all)
    }
    func layer(_ body: () -> Void) { ctx.beginTransparencyLayer(auxiliaryInfo: nil); body(); ctx.endTransparencyLayer() }
    // Removes the rectangle from what the current layer contains.
    func knockOut(_ r: CGRect) {
        ctx.saveGState(); ctx.setBlendMode(.destinationOut); fill(CGPath(rect: r, transform: nil), color(0)); ctx.restoreGState()
    }
    func paint(_ shape: CGPath, _ stops: Stops, _ box: CGRect) {
        ctx.saveGState(); ctx.addPath(shape); ctx.clip(using: .evenOdd); vertical(stops, box); ctx.restoreGState()
    }

    // Tile.
    let tile = squircle(tileRect, tileRadius)
    ctx.saveGState()
    setShadow(tileShadow)
    fill(tile, color(tileStops.last!.0))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    vertical(tileStops, tileRect)
    ctx.drawRadialGradient(gradient([(glow.hex, glow.alpha, 0), (glow.hex, 0, 1)]), startCenter: glow.center, startRadius: 0,
                           endCenter: glow.center, endRadius: tileRect.width * glow.radius, options: [])

    // Links. Each link is in its own layer, so a rectangle can cut the gap at the crossing where it is under.
    let sp = linkSpec(px)
    let w = sp.stroke, g = sp.gap
    let upper = CGRect(x: sp.phone.maxX - w - g, y: sp.mac.minY - 4, width: w + 2 * g, height: w + 8)
    let lower = CGRect(x: sp.phone.maxX - w - 4, y: sp.mac.maxY - w - g, width: w + 8, height: w + 2 * g)
    ctx.saveGState()
    if px >= 128 { setShadow(glyphShadow) }
    layer {
        layer {
            paint(ring(sp.mac, sp.radius, w), macStops, sp.mac)
            knockOut(upper)       // The phone link is on top here.
        }
        layer {
            paint(ring(sp.phone, sp.radius, w), phoneStops, sp.phone)
            knockOut(lower)       // The Mac link is on top here.
        }
    }
    ctx.restoreGState()

    if px > 32 {
        ctx.addPath(tile.copy(strokingWithWidth: 4, lineCap: .butt, lineJoin: .round, miterLimit: 10)); ctx.clip()
        ctx.drawLinearGradient(gradient([(0xFFFFFF, rimAlpha, 0), (0xFFFFFF, 0, 1)]), start: CGPoint(x: 0, y: tileRect.minY),
                               end: CGPoint(x: 0, y: tileRect.midY), options: all)
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let url = URL(fileURLWithPath: "\(out)/icon_\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(px), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}
print("wrote \(out)")
