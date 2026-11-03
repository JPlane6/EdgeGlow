import AppKit

/// Downloads album art and pulls a vivid primary/secondary color pair out of it.
final class ColorExtractor {
    static let shared = ColorExtractor()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 64
    }

    // MARK: Download

    func image(for urlString: String) async -> NSImage? {
        if let cached = cache.object(forKey: urlString as NSString) {
            return cached
        }
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: urlString as NSString)
            return image
        } catch {
            return nil
        }
    }

    // MARK: Palette

    private static let side = 32
    private static let bucketCount = 12

    private struct HueBucket {
        var weight = 0.0
        var hueX = 0.0
        var hueY = 0.0
        var saturation = 0.0
        var brightness = 0.0
        var count = 0
    }

    /// Returns nil when the artwork has no usable color (e.g. grayscale covers).
    static func palette(from image: NSImage) -> (primary: RGBColor, secondary: RGBColor)? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }

        // Normalize whatever we downloaded (grayscale, CMYK, Display P3, 16-bit…) by redrawing it into
        // a buffer we own with a fixed RGBA layout. Never read the source image's pixels directly.
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var buckets = Array(repeating: HueBucket(), count: bucketCount)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            // Un-premultiply.
            let r = min(Double(pixels[offset]) / 255 / alpha, 1)
            let g = min(Double(pixels[offset + 1]) / 255 / alpha, 1)
            let b = min(Double(pixels[offset + 2]) / 255 / alpha, 1)
            let (h, s, v) = hsb(r: r, g: g, b: b)

            // Skip near-black, near-white and washed-out pixels.
            guard v > 0.18, s > 0.25, !(v > 0.92 && s < 0.15) else { continue }

            let index = min(Int(h * Double(bucketCount)), bucketCount - 1)
            let weight = s * v
            let angle = h * 2 * .pi
            buckets[index].weight += weight
            buckets[index].hueX += cos(angle) * weight
            buckets[index].hueY += sin(angle) * weight
            buckets[index].saturation += s * weight
            buckets[index].brightness += v * weight
            buckets[index].count += 1
        }

        let ranked = buckets.indices.sorted { buckets[$0].weight > buckets[$1].weight }
        let primaryIndex = ranked[0]
        let primaryBucket = buckets[primaryIndex]
        guard primaryBucket.count >= 3 else { return nil }

        let primaryHSB = average(primaryBucket)
        let primary = vivid(primaryHSB)

        // Secondary: the strongest bucket at least 60° away, so the gradient actually has contrast.
        let secondaryIndex = ranked.dropFirst().first { index in
            let distance = abs(index - primaryIndex)
            let circular = min(distance, bucketCount - distance)
            return circular >= 2 && buckets[index].count >= 2 && buckets[index].weight >= primaryBucket.weight * 0.08
        }
        let secondary: RGBColor
        if let secondaryIndex {
            secondary = vivid(average(buckets[secondaryIndex]))
        } else {
            // Monochromatic art: derive an analogous hue so the rim still shimmers.
            let shifted = (primaryHSB.h + 0.12).truncatingRemainder(dividingBy: 1)
            secondary = vivid((shifted, primaryHSB.s, primaryHSB.v))
        }
        return (primary, secondary)
    }

    private static func average(_ bucket: HueBucket) -> (h: Double, s: Double, v: Double) {
        var hue = atan2(bucket.hueY, bucket.hueX) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return (hue, bucket.saturation / bucket.weight, bucket.brightness / bucket.weight)
    }

    /// Pushes a color into neon territory so the glow never looks muddy.
    private static func vivid(_ hsb: (h: Double, s: Double, v: Double)) -> RGBColor {
        rgb(h: hsb.h, s: max(hsb.s, 0.85), v: max(hsb.v, 0.95))
    }

    private static func hsb(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxC == 0 ? 0 : delta / maxC
        return (h, s, maxC)
    }

    private static func rgb(h: Double, s: Double, v: Double) -> RGBColor {
        let sector = (h * 6).truncatingRemainder(dividingBy: 6)
        let c = v * s
        let x = c * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGBColor(r: r + m, g: g + m, b: b + m)
    }
}
