import AppKit

/// Cached wrapped-text measurement (AppKit, so layouts can be computed outside a Canvas and match the
/// SF Pro text SwiftUI draws).
final class TextMeasure: @unchecked Sendable {
    static let shared = TextMeasure()
    private var cache: [String: CGSize] = [:]
    private let lock = NSLock()

    enum Design { case standard, rounded }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight, _ design: Design = .standard) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard design == .rounded, let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) else { return base }
        return f
    }

    /// Size of `text` wrapped to `width`, capped at `maxLines`.
    func size(_ text: String, size: CGFloat, weight: NSFont.Weight, design: Design = .standard, width: CGFloat, maxLines: Int = 0) -> CGSize {
        let key = "\(Int(size * 4))|\(weight.rawValue)|\(design)|\(Int(width))|\(maxLines)|\(text)"
        lock.lock()
        if let v = cache[key] { lock.unlock(); return v }
        lock.unlock()
        let font = Self.font(size, weight, design)
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        var h = ceil(rect.height)
        if maxLines > 0 { h = min(h, ceil((font.ascender - font.descender + font.leading) * CGFloat(maxLines)) + 1) }
        let result = CGSize(width: ceil(rect.width) + 1, height: h)
        lock.lock()
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = result
        lock.unlock()
        return result
    }
}

// MARK: - Feed physics

/// One item in a vertical feed (Messages thread, Money feed).
struct FeedEntry {
    var arrive: Double
    /// Items that leave again (typing indicators) collapse after this time.
    var leave: Double? = nil
    var height: CGFloat
    /// Space above the item.
    var gap: CGFloat
}

struct FeedPlacement {
    let index: Int
    /// Bottom edge of the item.
    let bottom: CGFloat
    /// 0…1+ (spring): how much of its height it occupies.
    let presence: Double
    /// Standard spring since arrival, for pop/squash/tilt.
    let enter: Double
    /// 0 for the newest item, 1 for the one above it, …
    let rank: Int
    /// Seconds since arrival.
    let age: Double
}

/// Stateless kinetic feed: every item that has arrived pushes the ones above it up by its height through
/// a spring, so the camera `travel`, its velocity (for motion blur) and each slot's entrance all follow
/// from timestamps, with no per-frame state.
enum FeedPhysics {
    static let response = 0.38, damping = 0.80

    static func presence(_ e: FeedEntry, at pos: Double) -> Double {
        var p = Motion.spring(pos - e.arrive, response: response, damping: damping)
        if let leave = e.leave { p *= 1 - Motion.clamp01(Motion.spring(pos - leave, response: 0.3, damping: 0.9)) }
        return p
    }

    static func place(_ entries: [FeedEntry], position pos: Double, bottom: CGFloat, top: CGFloat) -> (items: [FeedPlacement], velocity: CGFloat) {
        var out: [FeedPlacement] = []
        var cursor = bottom
        var rank = 0
        var velocity: CGFloat = 0
        // Newest first.
        var i = entries.count - 1
        while i >= 0 {
            let e = entries[i]
            defer { i -= 1 }
            guard e.arrive <= pos else { continue }
            if let leave = e.leave, pos - leave > 1 { continue }
            let p = presence(e, at: pos)
            let h = 1.0 / 240
            let dp = (presence(e, at: pos + h) - presence(e, at: pos - h)) / (2 * h)
            velocity += (e.height + e.gap) * CGFloat(dp)
            out.append(FeedPlacement(index: i, bottom: cursor, presence: p, enter: Motion.spring(pos - e.arrive), rank: rank, age: pos - e.arrive))
            cursor -= (e.height + e.gap) * CGFloat(p)
            rank += 1
            if cursor < top - 400 { break }
        }
        return (out, velocity)
    }
}
