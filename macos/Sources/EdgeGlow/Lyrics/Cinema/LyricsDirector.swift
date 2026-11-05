import AppKit
import Combine
import MetalKit
import QuartzCore

/// Owns the renderer, the style scenes and the semantic engine, and turns one `SceneInput` into one frame.
final class LyricsDirector {
    let renderer: LyricsMetalRenderer
    private var scenes: [LyricStyle: Scene3D] = [:]
    private let engine = SemanticKineticEngine()
    private let list = DrawList()
    private var signature = ""
    private var lastTime: Double?

    init?() {
        guard let renderer = LyricsMetalRenderer(), renderer.isReady else { return nil }
        self.renderer = renderer
    }

    private func make(_ style: LyricStyle) -> Scene3D {
        switch style {
        case .ship: return WallScene3D(icons: false, lens: false)
        case .visual: return WallScene3D(icons: true, lens: false)
        case .fisheye: return WallScene3D(icons: false, lens: true)
        case .fisheyeVisual: return WallScene3D(icons: true, lens: true)
        case .constellation: return ConstellationScene3D(icons: false)
        case .constellation3D: return ConstellationScene3D(icons: false, deep: true)
        case .hyperShip3D: return WallScene3D(icons: true, lens: false, stage: true)
        case .orbitalWeb3D: return OrbitalWebScene3D(icons: false)
        case .branches: return BranchesScene3D(icons: false)
        case .web: return WebScene3D(icons: false)
        case .codestyleVisual: return CodeScene3D(icons: true)
        }
    }

    func scene(for style: LyricStyle) -> Scene3D {
        if let s = scenes[style] { return s }
        let s = make(style)
        s.engine = engine
        scenes[style] = s
        // Only the current style keeps its caches.
        scenes = scenes.filter { $0.key == style }
        return s
    }

    /// Advances physics to `input.time` (no drawing); used by the preview harness and by `render`.
    @discardableResult
    func advance(_ input: SceneInput, style: LyricStyle) -> Scene3D {
        let sig = "\(input.lyrics.words.count)|\(input.lyrics.firstOnset)|\(input.lyrics.lastEnd)"
        let scene = scene(for: style)
        if sig != signature {
            signature = sig
            engine.prepare(input.lyrics)
            scene.reset()
            lastTime = nil
        }
        let dt = lastTime.map { min(max(input.time - $0, 0), 0.05) } ?? 0
        lastTime = input.time
        scene.update(input, dt: dt)
        return scene
    }

    func encode(_ input: SceneInput, style: LyricStyle, scene: Scene3D, alpha: Float, encoder: MTLRenderCommandEncoder) {
        let viewport = SIMD2<Float>(Float(input.size.width), Float(input.size.height))
        let frame = scene.camera.frame(viewport: viewport, fovFocal: viewport.y * 0.95)
        list.reset()
        scene.build(input, list: list, atlas: renderer.atlas, frame: frame)
        var lens: LensParams?
        if scene.usesLens {
            let centerY = viewport.y * (0.5 + Float(input.focusY - 0.5) * 0.5)
            lens = LensParams(center: SIMD2(viewport.x / 2, centerY), radii: SIMD2(viewport.x * 0.47, viewport.y * 0.45))
        }
        let hl = scene.highlight(input)
        renderer.encode(list: list, camera: frame, viewport: viewport, lens: lens, highlight: V3(hl.x, hl.y, hl.z),
                        time: Float(input.time), alpha: alpha, encoder: encoder)
    }
}

/// The single MTKView behind a lyrics overlay panel. It draws only while lyrics are loaded and music is
/// playing, so an idle overlay costs nothing.
final class LyricsMetalView: MTKView, MTKViewDelegate {
    private let model: LyricsModel
    private let state: AppState
    private let director: LyricsDirector?
    private var cancellables = Set<AnyCancellable>()

    /// Drawable resolution multiplier: sharp enough for large type, small enough for the memory budget.
    private static let maxScale: CGFloat = 1.25

    init(model: LyricsModel, state: AppState, director: LyricsDirector?) {
        self.model = model
        self.state = state
        self.director = director
        super.init(frame: .zero, device: GPU.shared.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        autoResizeDrawable = false
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = true
        (layer as? CAMetalLayer)?.isOpaque = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        layer?.backgroundColor = NSColor.clear.cgColor
        delegate = self

        // Run only while there is something to show.
        Publishers.CombineLatest(model.$lyrics.map { $0 != nil }, state.$playback.map { $0 == .playing })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasLyrics, playing in
                guard let self else { return }
                self.isPaused = !(hasLyrics && playing)
                if !(hasLyrics && playing) { self.draw() }     // one clear frame: nothing shows unless music plays
            }
            .store(in: &cancellables)
        state.$lyricStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.draw() }
            .store(in: &cancellables)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func layout() {
        super.layout()
        let scale = min(window?.backingScaleFactor ?? 2, Self.maxScale)
        let target = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if drawableSize != target { drawableSize = target }
    }

    func draw(in view: MTKView) {
        guard let director, let queue = GPU.shared.queue, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer {
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
        guard state.isPlaying, let lyrics = model.lyrics, !lyrics.isEmpty else { return }
        let now = CACurrentMediaTime()
        let pos = model.playhead(at: now)
        let levels = state.audioLevels.snapshot()
        let input = SceneInput(lyrics: lyrics, pos: pos, beat: model.rhythm.state(at: pos), theme: model.theme, size: drawableSize,
                               bass: levels.bass, vocal: levels.vocal, time: now, focusY: state.lyricVerticalPosition)
        let scene = director.advance(input, style: state.lyricStyle)
        director.encode(input, style: state.lyricStyle, scene: scene, alpha: 1, encoder: enc)
    }
}
