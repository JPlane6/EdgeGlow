import AppKit
import Combine
import SwiftUI

/// Album art for the lyric stage and the colors derived from it:
/// - the three lyric color slots (text, highlight, secondary): the user's custom `#RRGGBBAA` slots, or the
///   same artwork accents the glow rim uses, so text and rim always agree;
/// - `blooms`, up to five vivid perceptual accents for the Apple Money / Notification cards.
///
/// Spotify's cover comes from `artwork url of current track` (already downloaded by MediaBridge). Apple
/// Music exposes no URL, so its cover is read as `raw data of artwork 1 of current track`.
@MainActor
final class ArtworkColorSync: ObservableObject {
    /// Accent colors pulled from the artwork, brightest-weighted first.
    struct Palette: Equatable {
        var blooms: [Color]
    }

    @Published private(set) var artwork: NSImage?
    @Published private(set) var blooms: [Color] = []
    @Published private(set) var lyricPalette: LyricPalette = .fallback

    private let state: AppState
    private var bag = Set<AnyCancellable>()
    @Published private var rawArtwork: NSImage?
    private var rawKey = ""
    private var rawTask: Task<Void, Never>?
    private var bloomTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
    }

    var palette: Palette { Palette(blooms: blooms) }

    func start() {
        // Apple Music: fetch the embedded artwork once per track.
        Publishers.CombineLatest3(state.$mediaSource, state.$trackName, state.$artistName)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] source, title, artist in self?.trackChanged(source: source, key: "\(title)|\(artist)") }
            .store(in: &bag)

        // The image the stage shows: Apple Music's own cover when we have it, otherwise MediaBridge's.
        Publishers.CombineLatest(state.$artwork, $rawArtwork)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] downloaded, raw in self?.setArtwork(raw ?? downloaded) }
            .store(in: &bag)

        // Color slots follow the user's choices and the extracted rim colors.
        let triggers: [AnyPublisher<Void, Never>] = [
            state.$lyricColorsCustom.map { _ in () }.eraseToAnyPublisher(),
            state.$lyricTextColor.map { _ in () }.eraseToAnyPublisher(),
            state.$lyricHighlightColor.map { _ in () }.eraseToAnyPublisher(),
            state.$lyricSecondaryColor.map { _ in () }.eraseToAnyPublisher(),
            state.$useCustomColors.map { _ in () }.eraseToAnyPublisher(),
            state.$customPrimary.map { _ in () }.eraseToAnyPublisher(),
            state.$customSecondary.map { _ in () }.eraseToAnyPublisher(),
            state.$extractedPrimary.map { _ in () }.eraseToAnyPublisher(),
            state.$extractedSecondary.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputePalette() }
            .store(in: &bag)
        recomputePalette()
    }

    func stop() {
        bag.removeAll()
        rawTask?.cancel()
        bloomTask?.cancel()
    }

    // MARK: Palette

    private func recomputePalette() {
        let next: LyricPalette
        if state.lyricColorsCustom {
            next = LyricPalette(
                text: (RGBA(hex: state.lyricTextColor) ?? RGBA(r: 1, g: 1, b: 1)).color,
                highlight: (RGBA(hex: state.lyricHighlightColor) ?? RGBA(r: 0.37, g: 0.88, b: 1)).color,
                secondary: (RGBA(hex: state.lyricSecondaryColor) ?? RGBA(r: 0.7, g: 0.53, b: 1)).color)
        } else {
            let highlight = state.targetPrimary.color
            next = LyricPalette(text: Color.white.mixed(highlight, 0.08), highlight: highlight, secondary: state.targetSecondary.color)
        }
        if next != lyricPalette { lyricPalette = next }
        if blooms.isEmpty { blooms = [state.targetPrimary.color, state.targetSecondary.color] }
    }

    private func setArtwork(_ image: NSImage?) {
        guard image !== artwork else { return }
        artwork = image
        bloomTask?.cancel()
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            blooms = [state.targetPrimary.color, state.targetSecondary.color]
            return
        }
        let fallback = [state.targetPrimary.color, state.targetSecondary.color]
        let sendable = UncheckedImage(cg)
        bloomTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { Self.extractBlooms(sendable.value) }.value
            guard let self, !Task.isCancelled else { return }
            self.blooms = found.isEmpty ? fallback : found.map(\.color)
        }
    }

    /// Vivid hue clusters, weighted by saturation × brightness, pushed bright enough to glow on dark cards.
    nonisolated static func extractBlooms(_ image: CGImage, count: Int = 5) -> [RGBA] {
        let side = 28
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return [] }
        let buckets = 12
        var weight = [Double](repeating: 0, count: buckets)
        var sum = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: buckets)
        for o in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[o + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(pixels[o]) / 255 / a, g = Double(pixels[o + 1]) / 255 / a, b = Double(pixels[o + 2]) / 255 / a
            let ns = NSColor(srgbRed: min(r, 1), green: min(g, 1), blue: min(b, 1), alpha: 1)
            let h = Double(ns.hueComponent), s = Double(ns.saturationComponent), v = Double(ns.brightnessComponent)
            guard v > 0.2, s > 0.22 else { continue }
            let i = min(Int(h * Double(buckets)), buckets - 1)
            let w = s * v
            weight[i] += w
            sum[i].r += r * w; sum[i].g += g * w; sum[i].b += b * w
        }
        guard let top = weight.max(), top > 0 else { return [] }
        return weight.indices
            .filter { weight[$0] >= top * 0.06 }
            .sorted { weight[$0] > weight[$1] }
            .prefix(count)
            .map { i in
                let w = weight[i]
                let ns = NSColor(srgbRed: sum[i].r / w, green: sum[i].g / w, blue: sum[i].b / w, alpha: 1)
                let vivid = NSColor(hue: ns.hueComponent, saturation: max(ns.saturationComponent, 0.6),
                                    brightness: max(ns.brightnessComponent, 0.85), alpha: 1)
                return RGBA(vivid)
            }
    }

    // MARK: Apple Music artwork

    private func trackChanged(source: MediaSource?, key: String) {
        guard source == .appleMusic else {
            rawKey = ""
            rawTask?.cancel()
            if rawArtwork != nil { rawArtwork = nil }
            return
        }
        guard key != rawKey else { return }
        rawKey = key
        rawTask?.cancel()
        rawArtwork = nil
        rawTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { Self.appleMusicArtworkData() }.value
            guard let self, !Task.isCancelled, self.rawKey == key else { return }
            self.rawArtwork = data.flatMap(NSImage.init(data:))
        }
    }

    /// Runs in a separate `osascript` process (NSAppleScript is reserved for MediaBridge's script queue).
    /// The result prints as `«data JPEG FFD8…»`; the hex after the four-character type is the image.
    nonisolated private static func appleMusicArtworkData() -> Data? {
        let script = """
        tell application id "com.apple.Music"
            if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8),
              let open = text.range(of: "«data ") else { return nil }
        var hex = text[open.upperBound...].dropFirst(4)
        if let close = hex.firstIndex(of: "»") { hex = hex[..<close] }
        var bytes = Data(capacity: hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 65...70: v = c - 55
            case 97...102: v = c - 87
            default: continue
            }
            if let h = high { bytes.append(h << 4 | v); high = nil } else { high = v }
        }
        return bytes.isEmpty ? nil : bytes
    }
}

/// CGImage is immutable; this lets it cross into the detached extraction task.
private struct UncheckedImage: @unchecked Sendable {
    let value: CGImage
    init(_ value: CGImage) { self.value = value }
}
