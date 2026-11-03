// Procedurally renders the EdgeGlow app icon and emits every derived icon asset.
//   swiftc -O assets/make_icons.swift -o /tmp/make_icons && /tmp/make_icons assets
// Outputs (into the given directory):
//   AppIcon-1024.png   master artwork
//   AppIcon.iconset/   all sizes macOS wants (fed to `iconutil -c icns`)
//   AppIcon.ico        multi-resolution Windows icon (16, 32, 48, 64, 128, 256)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()

func ctx(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}

// Neon palette sampled by position around the rim: cyan -> violet -> magenta -> violet -> cyan.
func neon(_ t: Double) -> (Double, Double, Double) {
    let stops: [(Double, Double, Double)] = [(0, 229, 255), (139, 92, 246), (255, 45, 200), (139, 92, 246), (0, 229, 255)]
    let x = (t - floor(t)) * 4
    let i = min(Int(x), 3), f = x - Double(i)
    let s = f * f * (3 - 2 * f)
    let a = stops[i], b = stops[i + 1]
    return (a.0 + (b.0 - a.0) * s, a.1 + (b.1 - a.1) * s, a.2 + (b.2 - a.2) * s)
}

// Conic gradient image (CoreGraphics has none), rotated so cyan sits top-left.
func conicImage() -> CGImage {
    let c = ctx(S, S)
    let p = c.data!.assumingMemoryBound(to: UInt8.self)
    let m = Double(S) / 2
    for y in 0..<S {
        for x in 0..<S {
            let ang = atan2(Double(S - 1 - y) - m, Double(x) - m)
            let (r, g, b) = neon(ang / (2 * .pi) + 0.125)
            let o = (y * S + x) * 4
            p[o] = UInt8(r); p[o + 1] = UInt8(g); p[o + 2] = UInt8(b); p[o + 3] = 255
        }
    }
    return c.makeImage()!
}

func renderMaster() -> CGImage {
    let c = ctx(S, S)
    c.interpolationQuality = .high
    let inset: CGFloat = 64
    let body = CGRect(x: inset, y: inset, width: CGFloat(S) - 2 * inset, height: CGFloat(S) - 2 * inset)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let conic = conicImage()
    let full = CGRect(x: 0, y: 0, width: S, height: S)

    // Soft drop shadow under the chassis.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0, 0, 0, 0.55))
    c.addPath(path); c.setFillColor(rgb(10, 10, 18)); c.fillPath()
    c.restoreGState()

    // Dark chassis.
    c.saveGState()
    c.addPath(path); c.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(24, 21, 38), rgb(9, 9, 16)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(S) - inset), end: CGPoint(x: 0, y: inset), options: [])
    // Inner bloom: stacked low-alpha wide strokes, clipped to the chassis, fading toward the centre.
    for (w, a) in [(150.0, 0.05), (110.0, 0.07), (78.0, 0.10), (52.0, 0.14), (32.0, 0.2), (18.0, 0.3)] as [(CGFloat, CGFloat)] {
        c.saveGState()
        c.addPath(path); c.setLineWidth(w); c.replacePathWithStrokedPath(); c.clip()
        c.setAlpha(a); c.draw(conic, in: full)
        c.restoreGState()
    }
    // Waveform motif: symmetric rounded bars.
    let heights: [CGFloat] = [0.16, 0.30, 0.50, 0.74, 1.0, 0.68, 0.46, 0.28, 0.14]
    let barW: CGFloat = 40, gap: CGFloat = 28
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    let x0 = (CGFloat(S) - total) / 2, maxH: CGFloat = 400, cy = CGFloat(S) / 2
    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let r = CGRect(x: x0 + CGFloat(i) * (barW + gap), y: cy - maxH * h / 2, width: barW, height: maxH * h)
        bars.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    }
    c.saveGState()
    c.setShadow(offset: .zero, blur: 46, color: rgb(0, 229, 255, 0.75))
    c.addPath(bars); c.setFillColor(rgb(0, 229, 255, 0.9)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(bars); c.clip()
    let wg = CGGradient(colorsSpace: cs, colors: [rgb(0, 229, 255), rgb(139, 92, 246), rgb(255, 45, 200)] as CFArray, locations: [0, 0.5, 1])!
    c.drawLinearGradient(wg, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x0 + total, y: 0), options: [])
    c.restoreGState()
    // Spark: four-point star, top right of the waveform.
    let sc = CGPoint(x: 700, y: 760), sr: CGFloat = 52, sk: CGFloat = 10
    let star = CGMutablePath()
    star.move(to: CGPoint(x: sc.x, y: sc.y + sr))
    star.addQuadCurve(to: CGPoint(x: sc.x + sr, y: sc.y), control: CGPoint(x: sc.x + sk, y: sc.y + sk))
    star.addQuadCurve(to: CGPoint(x: sc.x, y: sc.y - sr), control: CGPoint(x: sc.x + sk, y: sc.y - sk))
    star.addQuadCurve(to: CGPoint(x: sc.x - sr, y: sc.y), control: CGPoint(x: sc.x - sk, y: sc.y - sk))
    star.addQuadCurve(to: CGPoint(x: sc.x, y: sc.y + sr), control: CGPoint(x: sc.x - sk, y: sc.y + sk))
    c.setShadow(offset: .zero, blur: 30, color: rgb(255, 255, 255, 0.9))
    c.addPath(star); c.setFillColor(rgb(255, 255, 255)); c.fillPath()
    c.restoreGState()

    // Crisp neon rim on top (full-strength conic through a thin stroke).
    c.saveGState()
    c.addPath(path); c.setLineWidth(10); c.replacePathWithStrokedPath(); c.clip()
    c.draw(conic, in: full)
    c.restoreGState()
    // Faint outer halo.
    for (w, a) in [(44.0, 0.05), (28.0, 0.08), (16.0, 0.12)] as [(CGFloat, CGFloat)] {
        c.saveGState()
        c.addPath(path); c.setLineWidth(w); c.replacePathWithStrokedPath(); c.clip()
        c.addPath(path); c.clip(using: .evenOdd) // keep only outside the body
        c.setAlpha(a); c.draw(conic, in: full)
        c.restoreGState()
    }
    return c.makeImage()!
}

func resized(_ img: CGImage, to size: Int) -> CGImage {
    var cur = img
    var w = img.width
    while w / 2 >= size {            // halve repeatedly for clean area-style filtering
        w /= 2
        let c = ctx(w, w); c.interpolationQuality = .high
        c.draw(cur, in: CGRect(x: 0, y: 0, width: w, height: w)); cur = c.makeImage()!
    }
    if w != size {
        let c = ctx(size, size); c.interpolationQuality = .high
        c.draw(cur, in: CGRect(x: 0, y: 0, width: size, height: size)); cur = c.makeImage()!
    }
    return cur
}

func png(_ img: CGImage) -> Data {
    let d = NSMutableData()
    let dest = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    return d as Data
}
func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 255) } }

// 32-bit BGRA DIB payload for an ICO entry (bottom-up, straight alpha, plus empty AND mask).
func dib(_ img: CGImage) -> Data {
    let w = img.width
    let c = ctx(w, w); c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: w))
    let p = c.data!.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](); out += le32(40) + le32(w) + le32(w * 2) + le16(1) + le16(32) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0)
    for y in stride(from: w - 1, through: 0, by: -1) {   // CG buffer is top-down; DIB is bottom-up
        for x in 0..<w {
            let o = (y * w + x) * 4
            let a = Int(p[o + 3])
            func un(_ v: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, Int(v) * 255 / a)) }
            out += [un(p[o + 2]), un(p[o + 1]), un(p[o]), UInt8(a)]
        }
    }
    out += [UInt8](repeating: 0, count: ((w + 31) / 32 * 4) * w)
    return Data(out)
}

let fm = FileManager.default
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
let master = renderMaster()
try png(master).write(to: outDir.appendingPathComponent("AppIcon-1024.png"))

// macOS iconset.
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(resized(master, to: base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(resized(master, to: base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// Windows .ico: small sizes as DIB (broadest compatibility), 128/256 as PNG.
let sizes = [16, 32, 48, 64, 128, 256]
var payloads = [Data]()
for s in sizes { let r = resized(master, to: s); payloads.append(s >= 128 ? png(r) : dib(r)) }
var ico = [UInt8]() + le16(0) + le16(1) + le16(sizes.count)
var offset = 6 + 16 * sizes.count
for (i, s) in sizes.enumerated() {
    ico += [UInt8(s == 256 ? 0 : s), UInt8(s == 256 ? 0 : s), 0, 0] + le16(1) + le16(32) + le32(payloads[i].count) + le32(offset)
    offset += payloads[i].count
}
var icoData = Data(ico); payloads.forEach { icoData.append($0) }
try icoData.write(to: outDir.appendingPathComponent("AppIcon.ico"))
print("icons written to \(outDir.path)")
