import Foundation
import NaturalLanguage
import simd

/// What one lyric word means physically.
struct SemanticTag {
    var archetype: Archetype = .none
    var symbol: String?
    /// Trailing `!` or `?`, which punch / tilt the camera even for words with no semantic match.
    var punct: Character?
    var lemma = ""
}

/// Per-frame modifiers applied to a word's quad.
struct WordMod {
    var scale = SIMD2<Float>(1, 1)
    /// Offset in word-height units.
    var offset = SIMD3<Float>(0, 0, 0)
    var roll: Float = 0
    /// Horizontal letter-spacing stretch (long held notes).
    var tracking: Float = 1
    /// Warm/cool light added behind the word: rgb + intensity.
    var glow = V4(0, 0, 0, 0)
    /// Heat shimmer amplitude (word-height units).
    var shimmer: Float = 0
    /// Chromatic split distance (word-height units).
    var split: Float = 0
}

/// Per-frame modifiers for a word's icon prop.
struct PropMod {
    var offset = SIMD3<Float>(0, 0, 0)
    var scale: Float = 1
    var roll: Float = 0
    var alpha: Float = 1
}

/// The smart choreography layer. Tags every lyric word with a kinetic archetype and an icon, and acts it
/// out: procedural word and prop micro-animations, camera impulses and trauma, and particles.
final class SemanticKineticEngine {
    private(set) var tags: [SemanticTag] = []
    let fx = KineticFX()
    private var lastActive = -1
    private var impactTime = -99.0
    private var impactSeed = 0

    func reset() {
        lastActive = -1; impactTime = -99
        fx.reset()
    }

    // MARK: Tagging

    /// NLTagger lemmas + the lexicon. Runs once per song.
    func prepare(_ lyrics: TimedLyrics) {
        reset()
        let tagger = NLTagger(tagSchemes: [.lemma])
        var result: [SemanticTag] = []
        result.reserveCapacity(lyrics.words.count)
        for word in lyrics.words {
            result.append(Self.tag(for: word.text, tagger: tagger))
        }
        tags = result
    }

    static func tag(for raw: String, tagger: NLTagger = NLTagger(tagSchemes: [.lemma])) -> SemanticTag {
        var tag = SemanticTag()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("!") { tag.punct = "!" } else if trimmed.hasSuffix("?") { tag.punct = "?" }
        let cleaned = trimmed.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        guard cleaned.count >= 2 else { return tag }

        var candidates = [cleaned]
        tagger.string = cleaned
        tagger.setLanguage(.english, range: cleaned.startIndex..<cleaned.endIndex)
        if let lemma = tagger.tag(at: cleaned.startIndex, unit: .word, scheme: .lemma).0?.rawValue.lowercased(), lemma != cleaned {
            candidates.append(lemma)
        }
        if cleaned.hasSuffix("in'") { candidates.append(String(cleaned.dropLast(3)) + "ing") }
        for c in candidates {
            for (archetype, words) in SemanticLexicon.all where words.contains(c) {
                tag.archetype = archetype
                tag.lemma = c
                tag.symbol = SemanticLexicon.glyphs[c] ?? SemanticLexicon.glyphs[cleaned] ?? SemanticLexicon.defaultGlyph[archetype]
                return tag
            }
        }
        tag.lemma = cleaned
        return tag
    }

    // MARK: Events

    struct Anchor {
        var center: V3
        var halfWidth: Float
        /// World height of one line of text.
        var unit: Float
    }

    /// Fires events when a new word becomes active and emits continuous effects for the active word.
    func update(input: SceneInput, dt: Double, anchor: (Int) -> Anchor?, camera: CinematicCamera3D) {
        fx.update(dt: Float(dt))
        guard let active = input.activeWord, tags.indices.contains(active) else { lastActive = input.activeWord ?? -1; return }
        let word = input.lyrics.words[active]
        let tag = tags[active]
        let age = max(0, input.pos - word.start)

        if active != lastActive {
            lastActive = active
            if let a = anchor(active) { trigger(tag: tag, word: word, anchor: a, input: input, camera: camera) }
        }

        guard anchor(active) != nil else { return }
        if word.duration > 0.8, age > 0.1 {
            // Long held note: slow dolly toward the word.
            camera.kick(dolly: -0.01 * dt * 60)
        }
    }

    /// Restrained, cinematic accents only: a soft bloom on warm and cosmic words and a slow camera nudge.
    /// No streaks, shock rings, shake or particles.
    private func trigger(tag: SemanticTag, word: TimedWord, anchor a: Anchor, input: SceneInput, camera: CinematicCamera3D) {
        switch tag.archetype {
        case .velocity: camera.kick(dolly: 0.12, yaw: -0.012)
        case .impact: camera.kick(dolly: 0.18, pitch: 0.012)
        case .fire: fx.emitFlare(at: a.center, size: a.unit * 2.6, life: 1.0, color: Self.warm)
        case .heart, .tears: camera.kick(dolly: 0.06)
        case .cosmic: fx.emitFlare(at: a.center + V3(0, a.unit * 0.2, 0), size: a.unit * 3.0, life: 1.2, color: V4(0.75, 0.88, 1, 1))
        case .vibe, .none: break
        }
    }

    private static func isLightning(_ lemma: String) -> Bool {
        ["thunder", "lightning", "bolt", "storm", "strike", "shock", "electric"].contains(lemma)
    }

    static let warm = V4(1.0, 0.55, 0.14, 1)
    static let crimson = V4(1.0, 0.16, 0.38, 1)
    static let water = V4(0.55, 0.82, 1.0, 1)

    // MARK: Per-word modifiers

    func wordMod(index: Int, input: SceneInput, isActive: Bool, indexInView: Int = 0) -> WordMod {
        var m = WordMod()
        guard tags.indices.contains(index) else { return m }
        let word = input.lyrics.words[index]
        let tag = tags[index]
        let age = Float(max(0, input.pos - word.start))

        guard isActive else { return m }
        // Active word: spring scale 1.0 → 1.12 (stiffness 220, damping 24) with a soft accent bloom.
        let k = Float(Self.spring(Double(age)))
        let sc = 1 + 0.12 * k
        m.scale = SIMD2(repeating: sc)
        m.offset.z = -0.03 * k
        let accent: V4
        switch tag.archetype {
        case .heart, .tears: accent = V4(Self.crimson.x, Self.crimson.y, Self.crimson.z, 0.28)
        case .fire: accent = V4(Self.warm.x, Self.warm.y, Self.warm.z, 0.28)
        case .cosmic: accent = V4(0.6, 0.78, 1, 0.24)
        default: accent = V4(0, 0, 0, 0)
        }
        m.glow = accent
        if word.duration > 0.8 { m.tracking = 1 + 0.04 * min(1, age / Float(word.duration)) }
        return m
    }

    /// Critically-damped-ish spring step response (stiffness 220, damping 24): fast, no visible overshoot.
    static func spring(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w = 220.0.squareRoot(), z = 24.0 / (2 * w)
        if z >= 1 { let e = exp(-w * t); return 1 - e * (1 + w * t) }
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    /// Icon prop animation relative to its resting spot beside the word.
    func propMod(index: Int, input: SceneInput) -> PropMod {
        var p = PropMod()
        guard tags.indices.contains(index) else { return p }
        let age = Double(max(0, input.pos - input.lyrics.words[index].start))
        // Smooth pop-in 0.5 → 1.0.
        p.scale = Float(0.5 + 0.5 * min(1, max(0, Self.spring(age))))
        return p
    }

    /// Archetype color for props and rings (falls back to `fallback`).
    func tint(_ index: Int, fallback: V4) -> V4 {
        guard tags.indices.contains(index) else { return fallback }
        switch tags[index].archetype {
        case .heart: return Self.crimson
        case .tears: return Self.water
        case .fire: return Self.warm
        case .velocity: return V4(1, 1, 1, 1)
        case .impact: return V4(1, 0.95, 0.8, 1)
        default: return fallback
        }
    }

    // MARK: Drawing

    func draw(into list: DrawList, camera: CameraFrame) {
        fx.draw(into: list, camera: camera)
    }
}

/// Deterministic hash shared by the 3D scenes.
enum CanvasKitHash {
    static func hash(_ seed: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: seed) &* 0x9E3779B97F4A7C15
        x ^= x >> 30; x = x &* 0xBF58476D1CE4E5B9
        x ^= x >> 27; x = x &* 0x94D049BB133111EB
        x ^= x >> 31
        return Double(x % 1_000_000) / 1_000_000
    }
}

// MARK: - Particles

/// Embers, droplets, shock rings, skid streaks, lightning bolts, star flares and sparks.
final class KineticFX {
    enum Kind { case ember, drop, ring, streak, bolt, flare, spark }

    struct Particle {
        var kind: Kind
        var pos: V3
        var vel = V3(0, 0, 0)
        var age: Float = 0
        var life: Float
        var size: Float
        var color: V4
        var aux: Float = 0
        var end = V3(0, 0, 0)
        var delay: Float = 0
    }

    private(set) var particles: [Particle] = []
    private var seed = 1
    private let maxParticles = 420

    func reset() { particles.removeAll() }

    private func rnd() -> Float {
        seed &+= 1
        return Float(CanvasKitHash.hash(seed &* 2654435761))
    }

    private func add(_ p: Particle) {
        if particles.count >= maxParticles { particles.removeFirst(16) }
        particles.append(p)
    }

    func emitEmbers(at p: V3, width: Float, unit: Float, count: Int, color: V4) {
        for _ in 0..<max(1, count) {
            let x = (rnd() * 2 - 1) * width
            add(Particle(kind: .ember, pos: p + V3(x, 0, 0), vel: V3((rnd() - 0.5) * unit * 0.8, unit * (1.2 + rnd() * 1.8), 0),
                         life: 0.9 + rnd() * 0.9, size: unit * (0.05 + rnd() * 0.08), color: color, aux: rnd() * 6))
        }
    }

    func emitDrops(at p: V3, width: Float, unit: Float, count: Int, color: V4) {
        for _ in 0..<count {
            add(Particle(kind: .drop, pos: p + V3((rnd() * 2 - 1) * width, 0, 0), vel: V3(0, -unit * 0.4, 0),
                         life: 1.3, size: unit * 0.10, color: color))
        }
    }

    func emitRing(at p: V3, radius: Float, life: Float, color: V4, thickness: Float, delay: Float = 0) {
        add(Particle(kind: .ring, pos: p, life: life, size: radius, color: color, aux: thickness, delay: delay))
    }

    func emitFlare(at p: V3, size: Float, life: Float, color: V4) {
        add(Particle(kind: .flare, pos: p, life: life, size: size, color: color))
    }

    func emitSparks(at p: V3, unit: Float, count: Int, color: V4) {
        for _ in 0..<count {
            let a = rnd() * 2 * .pi, s = unit * (2 + rnd() * 5)
            add(Particle(kind: .spark, pos: p, vel: V3(cos(a) * s, sin(a) * s, (rnd() - 0.5) * s * 0.3), life: 0.5 + rnd() * 0.5, size: unit * 0.07, color: color))
        }
    }

    func emitStreaks(at p: V3, halfWidth: Float, unit: Float, color: V4) {
        for k in 0..<7 {
            let y = (Float(k) - 3) * unit * 0.2 + (rnd() - 0.5) * unit * 0.1
            let len = unit * (2.5 + rnd() * 3)
            add(Particle(kind: .streak, pos: p + V3(-halfWidth * 0.8, y, 0), vel: V3(-unit * 6, 0, 0), life: 0.55, size: unit * 0.035, color: color, aux: len))
        }
    }

    func emitBolt(from a: V3, to b: V3, seed s: Int, color: V4) {
        add(Particle(kind: .bolt, pos: a, life: 0.32, size: 0.05, color: color, aux: Float(s), end: b))
    }

    func update(dt: Float) {
        guard dt > 0 else { return }
        for i in particles.indices {
            if particles[i].delay > 0 { particles[i].delay -= dt; continue }
            particles[i].age += dt
            switch particles[i].kind {
            case .ember:
                particles[i].vel.x += sin(particles[i].age * 7 + particles[i].aux) * dt * particles[i].size * 60
                particles[i].pos += particles[i].vel * dt
            case .drop:
                particles[i].vel.y -= dt * 900 * 0.35
                particles[i].pos += particles[i].vel * dt
            case .spark:
                particles[i].vel.y -= dt * 520
                particles[i].pos += particles[i].vel * dt
                particles[i].vel *= 0.985
            case .streak:
                particles[i].pos += particles[i].vel * dt
                particles[i].vel.x *= 0.93
            default: break
            }
        }
        particles.removeAll { $0.age >= $0.life }
    }

    func draw(into list: DrawList, camera: CameraFrame) {
        for p in particles where p.delay <= 0 {
            let k = p.age / p.life           // 0 → 1
            let fade = 1 - k
            var c = p.color
            switch p.kind {
            case .ember:
                c.w = fade * 0.9
                list.sprite(.glow, at: p.pos, radius: p.size * (1 + 0.6 * fade), color: c, extra: 2, camera: camera)
            case .drop:
                c.w = min(1, fade * 1.4)
                list.sprite(.glow, at: p.pos, radius: p.size, color: c, extra: 1.6, camera: camera)
                list.ribbon(from: p.pos, to: p.pos + V3(0, p.size * 4, 0), width: p.size * 0.5, color: c * V4(1, 1, 1, 0.5), glow: 0.3, camera: camera)
            case .ring:
                let eased = 1 - pow(1 - k, 2.2)
                c.w = pow(fade, 1.4)
                list.sprite(.ring, at: p.pos, radius: p.size * (0.15 + 0.85 * eased), color: c, extra: p.aux, camera: camera)
            case .flare:
                c.w = fade * min(1, k * 8)
                list.sprite(.flare, at: p.pos, radius: p.size * (0.7 + 0.5 * sin(k * .pi)), color: c, camera: camera)
            case .spark:
                c.w = fade
                list.sprite(.glow, at: p.pos, radius: p.size, color: c, extra: 1.8, camera: camera)
            case .streak:
                c.w = fade * 0.8
                list.ribbon(from: p.pos, to: p.pos + V3(p.aux * (0.4 + 0.6 * k), 0, 0), width: p.size, color: c, glow: 0.5, camera: camera)
            case .bolt:
                c.w = fade
                var prev = p.pos
                let segments = 8
                let d = p.end - p.pos
                for s in 1...segments {
                    let t = Float(s) / Float(segments)
                    var q = p.pos + d * t
                    if s < segments {
                        let jitter = Float(CanvasKitHash.hash(Int(p.aux) * 131 + s * 17 + Int(p.age * 60))) - 0.5
                        q.x += jitter * simd_length(d) * 0.45
                    }
                    list.ribbon(from: prev, to: q, width: simd_length(d) * 0.05, color: c, glow: 0.9, camera: camera)
                    prev = q
                }
            }
        }
    }
}
