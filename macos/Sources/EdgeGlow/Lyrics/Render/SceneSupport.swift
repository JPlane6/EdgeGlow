import SwiftUI

// MARK: - Scene input

/// Everything a lyric scene needs to draw one frame.
struct SceneInput {
    let lyrics: TimedLyrics
    let pos: Double
    let beat: BeatState
    let theme: LyricTheme
    /// Drawable size in pixels.
    let size: CGSize
    /// Live bass and vocal band energies (0…1) from EdgeGlow's FFT (or Cloud Sync when the Mac is silent).
    var bass: Double = 0
    var vocal: Double = 0
    /// Monotonic wall-clock time of this frame (`CACurrentMediaTime()`), for springs and idle motion.
    var time: Double = 0
    /// 0…1 vertical focus position from the popover slider.
    var focusY: Double = 0.5
    let cursor: LineCursor

    init(lyrics: TimedLyrics, pos: Double, beat: BeatState, theme: LyricTheme, size: CGSize,
         bass: Double = 0, vocal: Double = 0, time: Double = 0, focusY: Double = 0.5) {
        self.lyrics = lyrics; self.pos = pos; self.beat = beat; self.theme = theme; self.size = size
        self.bass = bass; self.vocal = vocal; self.time = time; self.focusY = focusY
        self.cursor = lyrics.cursor(at: pos)
    }

    func progress(_ w: TimedWord) -> Double {
        if w.duration <= 0.001 { return pos >= w.start ? 1 : 0 }
        return min(1, max(0, (pos - w.start) / w.duration))
    }

    /// Index (into `lyrics.words`) of the last word that has started, or nil before the first one.
    var activeWord: Int? {
        let words = lyrics.words
        var lo = 0, hi = words.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if words[mid].start <= pos { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found >= 0 ? found : nil
    }
}

// MARK: - Helpers

enum CanvasKit {
    /// Damped-spring pop-in: 0 at t = 0, overshoots, settles at 1.
    static func spring(_ t: Double) -> Double {
        t <= 0 ? 0 : 1 - exp(-9 * t) * cos(16 * t)
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x)); return t * t * (3 - 2 * t)
    }

    static func hash(_ seed: Int) -> Double { CanvasKitHash.hash(seed) }
}
