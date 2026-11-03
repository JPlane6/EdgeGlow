using System;
using System.Collections.Generic;
using System.Linq;
using SkiaSharp;

namespace EdgeGlow;

/// <summary>
/// Full-screen liquid rim that hugs the display bezel, pulsing with the bass and chasing with the vocals.
/// One instance per display, so physics and sparks are per screen. This is a line-for-line port of the
/// macOS GlowRenderer: same constants, same spring-mass string, same transient detection, drawn with
/// SkiaSharp. All coordinates are in device-independent points (the host scales the canvas).
/// </summary>
public sealed class GlowRenderer
{
    // ---- Animation state ----
    private bool _hasLast;
    private double _lastTime;
    private double _angle;
    private double _pulse;
    private double _presence;
    private RgbColor _primary = RgbColor.NeonCyan;
    private RgbColor _secondary = RgbColor.NeonMagenta;
    /// <summary>Chasing: leading comet head position along the perimeter (0..1, clockwise from top-center) and its smoothed speed in laps/s.</summary>
    private double _chasePosition;
    private double _chaseRate;
    /// <summary>Symmetry: direction of the current pass (true = top-center to bottom-center); flips at every merge.</summary>
    private bool _symmetryTopToBottom = true;
    private double _symmetryProgress;
    private bool _symmetryDraining;

    private const double ChaseGlideRate = 1.0 / 12.0;
    private const double ChaseVocalBoost = 0.6;
    private const double SymmetrySpeed = 1.25;

    // ---- Kinetic physics ----
    private readonly record struct EdgeNode(SKPoint Point, SKPoint Normal, double Angle);

    private struct Spark
    {
        public double X, Y, Vx, Vy, Age, Life, Size;
        public RgbColor Color;
    }

    private const int NodeCount = 240;
    private const float CornerRadius = 16f;
    // The bezel is a closed spring-mass string: tension carries ripples along the edge (~75 nodes/s),
    // stiffness pulls each node back to rest (~4 Hz wobble) and damping rings it down within ~1 s.
    private const double StringTension = 5_600.0;
    private const double StringStiffness = 630.0;
    private const double StringDamping = 5.0;
    private const int MaxSparks = 180;
    private const double SparkLinkDistance = 130.0;
    private const float SampleSpacing = 4f;

    private EdgeNode[] _nodes = Array.Empty<EdgeNode>();
    private OutlineSample[] _samples = Array.Empty<OutlineSample>();
    private (float W, float H) _geometrySize;
    private double[] _displacement = new double[NodeCount];
    private double[] _displacementVelocity = new double[NodeCount];
    private bool _stringAwake;
    private readonly List<Spark> _sparks = new();
    private double _bassAverage, _vocalAverage, _bassCooldown, _vocalCooldown;
    private double _shake;
    private readonly Random _rng = new();

    // Per-frame disposables (image filters, shaders).
    private readonly List<IDisposable> _frame = new();

    public void Draw(SKCanvas canvas, float width, float height, double now, AppState state)
    {
        var dt = _hasLast ? Math.Min(Math.Max(now - _lastTime, 0), 1.0 / 15.0) : 0;
        _lastTime = now;
        _hasLast = true;

        // Frame-rate independent exponential smoothing.
        double Approach(double rate) => 1 - Math.Exp(-dt * rate);

        var style = state.AnimationStyle;
        var playing = state.IsPlaying;
        var targetPresence = playing ? 1.0 : (state.IdleWhenPaused ? 0.55 : 0.0);
        _presence += (targetPresence - _presence) * Approach(2.5);

        // Liquid crossfade toward the current album colors.
        _primary = _primary.Lerp(state.TargetPrimary, Approach(2.2));
        _secondary = _secondary.Lerp(state.TargetSecondary, Approach(2.2));

        var spinRate = playing ? 0.35 : 0.12;
        _angle = (_angle + dt * spinRate) % (2 * Math.PI);

        // Live system-audio energies (already envelope-followed on the audio thread).
        var audioReactive = state.AudioReactive;
        var levels = audioReactive ? state.AudioLevels.Snapshot() : (Bass: 0.0, Vocal: 0.0);

        double rawPulse;
        if (audioReactive)
        {
            rawPulse = levels.Bass; // the kick drives the pulse directly
        }
        else
        {
            // Slow ambient breathing while idle.
            rawPulse = 0.35 * Math.Pow(0.5 + 0.5 * Math.Sin(2 * Math.PI * now / 6), 2.2);
        }
        // Light smoothing turns ~50 Hz audio updates into a fluid 60 fps pulse without dulling the kick.
        _pulse += (rawPulse - _pulse) * Approach(30);

        // Vocal velocity: the comets glide when there's no singing and surge on dense vocals.
        double targetChaseRate;
        if (audioReactive) targetChaseRate = ChaseGlideRate + ChaseVocalBoost * Math.Pow(levels.Vocal, 1.5);
        else targetChaseRate = playing ? 1.0 / 8.0 : 1.0 / 14.0;
        _chaseRate += (targetChaseRate - _chaseRate) * Approach(targetChaseRate > _chaseRate ? 6 : 1.2);
        _chasePosition = (_chasePosition + dt * _chaseRate) % 1;

        // Symmetry: alternating passes. The moment the mirrored heads merge, the direction flips and the
        // next pair launches from that same point, while the previous pair's tails finish draining into it.
        _symmetryProgress += dt * _chaseRate * SymmetrySpeed;
        var merged = false;
        if (_symmetryProgress >= 0.5)
        {
            _symmetryProgress = (_symmetryProgress - 0.5) % 0.5;
            _symmetryTopToBottom = !_symmetryTopToBottom;
            _symmetryDraining = true;
            merged = style == AnimationStyle.Symmetry;
        }
        if (_symmetryDraining && _symmetryProgress >= state.CometLength) _symmetryDraining = false;

        PrepareGeometry(width, height);
        // Physics keeps stepping even while faded out, so ripples and sparks always settle cleanly.
        // Sparks Only *is* the kinetic effect, so it ignores the toggle.
        var kinetic = state.KineticEffects || style == AnimationStyle.SparksOnly;
        UpdateKinetics(dt, levels, audioReactive && kinetic, merged, state);

        if (_presence > 0.002)
        {
            var beat = _pulse * state.Reactivity;
            var opacity = state.Intensity * _presence;
            // Heavy impact: split the rim's color channels while the bass envelope is above 0.8.
            var aberration = kinetic && audioReactive ? Math.Min(Math.Max((levels.Bass - 0.8) / 0.2, 0), 1) : 0;

            canvas.Save();
            if (_shake > 0.01)
            {
                var amplitude = Math.Min(_shake, 1.5) * 6;
                canvas.Translate((float)(amplitude * Math.Sin(now * 83)), (float)(amplitude * Math.Cos(now * 71)));
            }

            switch (style)
            {
                case AnimationStyle.Breathing:
                    // Bass blooms the blur slightly on each kick.
                    DrawRim(canvas, width, height, beat, 0.9 + 0.3 * beat, opacity, aberration, state);
                    break;
                case AnimationStyle.Chasing:
                    DrawComets(canvas, new List<Comet>
                    {
                        new(_chasePosition, 1, null),
                        new(_chasePosition + 0.5, 1, null),
                    }, width, height, beat, opacity, aberration, state);
                    break;
                case AnimationStyle.Symmetry:
                    var comets = SymmetryComets(_symmetryProgress, _symmetryTopToBottom);
                    if (_symmetryDraining)
                    {
                        // The previous pass, carried past its merge point so its clipped tails drain into it.
                        comets.AddRange(SymmetryComets(0.5 + _symmetryProgress, !_symmetryTopToBottom));
                    }
                    DrawComets(canvas, comets, width, height, beat, opacity, aberration, state);
                    DrawMergeGlow(canvas, width, height, beat, opacity, state);
                    break;
                case AnimationStyle.SparksOnly:
                    // No rim: the dark bezel is only revealed by the sparks it throws.
                    break;
            }
            canvas.Restore();

            DrawSparks(canvas, opacity);
        }

        foreach (var d in _frame) d.Dispose();
        _frame.Clear();
    }

    // ---- Paint helpers ----

    private static byte A(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255, MidpointRounding.AwayFromZero);

    private static SKColor Col(RgbColor c, double alpha = 1) =>
        new(RgbColor.ToByte(c.R), RgbColor.ToByte(c.G), RgbColor.ToByte(c.B), A(alpha));

    private SKImageFilter Blur(double sigma)
    {
        var s = (float)Math.Max(sigma, 0.01);
        var filter = SKImageFilter.CreateBlur(s, s);
        _frame.Add(filter);
        return filter;
    }

    private SKPaint StrokePaint(double width, SKColor color, SKStrokeCap cap = SKStrokeCap.Butt) => new()
    {
        IsAntialias = true,
        Style = SKPaintStyle.Stroke,
        StrokeWidth = (float)width,
        StrokeCap = cap,
        StrokeJoin = SKStrokeJoin.Round,
        Color = color,
    };

    /// <summary>The rotating five-stop primary/secondary conic gradient of the breathing rim.</summary>
    private SKShader Conic(float width, float height)
    {
        float cx = width / 2, cy = height / 2;
        var colors = new[] { Col(_primary), Col(_secondary), Col(_primary), Col(_secondary), Col(_primary) };
        var positions = new[] { 0f, 0.25f, 0.5f, 0.75f, 1f };
        using var sweep = SKShader.CreateSweepGradient(new SKPoint(cx, cy), colors, positions);
        var rotated = sweep.WithLocalMatrix(SKMatrix.CreateRotation((float)_angle, cx, cy));
        _frame.Add(rotated);
        return rotated;
    }

    // ---- Breathing ----

    /// <summary>The original two-layer rim with a rotating conic gradient.</summary>
    private void DrawRim(SKCanvas canvas, float w, float h, double beat, double bloom, double opacity, double aberration, AppState state)
    {
        var shader = Conic(w, h);

        // Layer 1: ambient spill. The stroke is centered on the bezel, so the inner half bleeds onto the screen.
        using (var ambientPath = EdgePath(w, h, 0))
        using (var ambient = StrokePaint(state.Thickness * (0.75 + 0.55 * beat), new SKColor(255, 255, 255, A(opacity))))
        {
            ambient.Shader = shader;
            ambient.ImageFilter = Blur(state.GlowSpread * bloom);
            canvas.DrawPath(ambientPath, ambient);
        }

        // Layer 2: crisp neon core pressed right against the bezel.
        var rimWidth = Math.Max(4, state.Thickness * 0.22) * (1 + 0.25 * beat);
        using (var rimPath = EdgePath(w, h, rimWidth * 0.25))
        using (var rim = StrokePaint(rimWidth, new SKColor(255, 255, 255, A(Math.Min(1, opacity * (0.85 + 0.3 * beat)) * (1 - 0.45 * aberration)))))
        {
            rim.Shader = shader;
            rim.ImageFilter = Blur(8);
            canvas.DrawPath(rimPath, rim);
        }

        DrawChromaticSplit(canvas, rimWidth * 0.25, aberration, opacity, (layer, inset) =>
        {
            using var path = EdgePath(w, h, inset);
            using var paint = StrokePaint(rimWidth * 0.8, SKColors.White);
            paint.Shader = shader;
            layer.DrawPath(path, paint);
        });
    }

    // ---- Comets (Chasing, Symmetry) ----

    /// <summary>One comet of light on the bezel. Positions are perimeter fractions clockwise from top-center and may exceed 0..1 (they wrap) unless clipped.</summary>
    private readonly record struct Comet(double Head, double Direction, (double Lo, double Hi)? Clip);

    /// <summary>Each comet is a stack of overlapping trims sharing the head and reaching progressively further back, so brightness ramps smoothly from head to tail.</summary>
    private const int CometLayerCount = 12;

    /// <summary>Per-layer alpha chosen so the stacked result follows brightness(x) = (1 - x)^1.6 along the comet.</summary>
    private static readonly double[] CometLayerAlphas = BuildCometAlphas();

    private static double[] BuildCometAlphas()
    {
        var n = CometLayerCount;
        var brightness = Enumerable.Range(0, n + 1).Select(j => j == n ? 0 : Math.Pow(1 - (double)j / n, 1.6)).ToArray();
        return Enumerable.Range(0, n).Select(j => 1 - (1 - brightness[j]) / (1 - brightness[j + 1])).ToArray();
    }

    private RgbColor CometHeadColor => _primary.Lerp(RgbColor.White, 0.35);

    /// <summary>Color at fraction t along a comet: white-hot head, primary body, secondary tail.</summary>
    private RgbColor CometColor(double t) =>
        t < 0.3 ? CometHeadColor.Lerp(_primary, t / 0.3) : _primary.Lerp(_secondary, (t - 0.3) / 0.7);

    /// <summary>Comets over an otherwise dark bezel, with the same ambient spill + crisp core layering as the rim. Vocals set their speed (upstream); the bass owns their body.</summary>
    private void DrawComets(SKCanvas canvas, List<Comet> comets, float w, float h, double beat, double opacity, double aberration, AppState state)
    {
        var length = state.CometLength;

        using (var ambientPath = EdgePath(w, h, 0))
        using (var layerPaint = new SKPaint { Color = new SKColor(255, 255, 255, A(opacity * (0.7 + 0.3 * Math.Min(beat, 1)))) })
        {
            layerPaint.ImageFilter = Blur(state.GlowSpread * (0.8 + 0.45 * beat));
            canvas.SaveLayer(layerPaint);
            StrokeComets(canvas, comets, ambientPath, length, state.Thickness * (0.85 + 0.55 * beat));
            canvas.Restore();
        }

        var rimWidth = Math.Max(4, state.Thickness * 0.22) * (1 + 0.25 * beat);
        using var rimPath = EdgePath(w, h, rimWidth * 0.25);
        using (var layerPaint = new SKPaint { Color = new SKColor(255, 255, 255, A(Math.Min(1, opacity * (0.75 + 0.4 * beat)) * (1 - 0.45 * aberration))) })
        {
            layerPaint.ImageFilter = Blur(8 * (1 + 0.5 * beat));
            canvas.SaveLayer(layerPaint);
            StrokeComets(canvas, comets, rimPath, length, rimWidth);
            canvas.Restore();
        }

        // White-hot point at each head.
        using (var core = StrokePaint(rimWidth * 0.7, Col(CometHeadColor.Lerp(RgbColor.White, 0.4), opacity * (0.75 + 0.25 * Math.Min(beat, 1))), SKStrokeCap.Round))
        {
            core.BlendMode = SKBlendMode.Plus;
            core.ImageFilter = Blur(4 + 2 * beat);
            var coreReach = Math.Min(0.008, length * 0.2);
            using var measure = new SKPathMeasure(rimPath, false);
            using var segment = new SKPath();
            foreach (var comet in comets)
            {
                var range = CometRange(comet, coreReach);
                if (range == null) continue;
                segment.Rewind();
                AddSegment(measure, range.Value.From, range.Value.To, segment);
                canvas.DrawPath(segment, core);
            }
        }

        DrawChromaticSplit(canvas, rimWidth * 0.25, aberration, opacity, (layer, inset) =>
        {
            using var path = EdgePath(w, h, inset);
            StrokeComets(layer, comets, path, length, rimWidth * 0.8);
        });
    }

    private void StrokeComets(SKCanvas canvas, List<Comet> comets, SKPath path, double length, double lineWidth)
    {
        var n = CometLayerCount;
        using var measure = new SKPathMeasure(path, false);
        using var segment = new SKPath();
        using var paint = StrokePaint(lineWidth, SKColors.White, SKStrokeCap.Round);
        foreach (var comet in comets)
        {
            // Longest (tail) first, so the brighter head layers composite on top.
            for (var k = n - 1; k >= 0; k--)
            {
                var range = CometRange(comet, length * (k + 1) / n);
                if (range == null) continue;
                paint.Color = Col(CometColor((double)k / (n - 1)), CometLayerAlphas[k]);
                segment.Rewind();
                AddSegment(measure, range.Value.From, range.Value.To, segment);
                canvas.DrawPath(segment, paint);
            }
        }
    }

    /// <summary>The stretch of perimeter covered by a comet from its head back <paramref name="reach"/>, after clipping.</summary>
    private static (double From, double To)? CometRange(Comet comet, double reach)
    {
        var from = comet.Direction > 0 ? comet.Head - reach : comet.Head;
        var to = comet.Direction > 0 ? comet.Head : comet.Head + reach;
        if (comet.Clip is { } clip)
        {
            from = Math.Max(from, clip.Lo);
            to = Math.Min(to, clip.Hi);
        }
        return to - from > 0.0005 ? (from, to) : null;
    }

    /// <summary>Appends the part of the closed bezel between perimeter fractions from and to (to &gt; from), wrapping across the top-center start point when needed.</summary>
    private static void AddSegment(SKPathMeasure measure, double from, double to, SKPath dst)
    {
        var length = measure.Length;
        if (length <= 0) return;
        var shift = Math.Floor(from);
        var a = from - shift;
        var b = to - shift;
        if (b <= 1)
        {
            measure.GetSegment((float)(a * length), (float)(b * length), dst, true);
            return;
        }
        measure.GetSegment((float)(a * length), length, dst, true);
        measure.GetSegment(0, (float)(Math.Min(b - 1, 1) * length), dst, true);
    }

    // ---- Symmetry ----

    /// <summary>Perimeter fraction where a Symmetry pass starts: top-center (0) or bottom-center (0.5). The pass merges at the other one.</summary>
    private static double SymmetryOrigin(bool topToBottom) => topToBottom ? 0 : 0.5;

    /// <summary>The mirrored pair of one Symmetry pass at progress p (0..0.5, or beyond while draining). Each comet is clipped to its own half, so at the merge point they fuse instead of passing.</summary>
    private static List<Comet> SymmetryComets(double p, bool topToBottom)
    {
        if (topToBottom)
        {
            // Right comet clockwise down the right edge, left comet counter-clockwise down the left.
            return new List<Comet> { new(p, 1, (0, 0.5)), new(1 - p, -1, (0.5, 1)) };
        }
        // Right comet counter-clockwise up the right edge, left comet clockwise up the left.
        return new List<Comet> { new(0.5 - p, -1, (0, 0.5)), new(0.5 + p, 1, (0.5, 1)) };
    }

    /// <summary>Merge blooms as (perimeter fraction, strength): one swelling at the destination as the heads close in, and one fading at the origin while the previous pair's tails drain into it.</summary>
    private List<(double Point, double Glow)> SymmetryBlooms(double cometLength)
    {
        var p = _symmetryProgress;
        var origin = SymmetryOrigin(_symmetryTopToBottom);
        var blooms = new List<(double, double)>();
        var t = Math.Min(Math.Max((p - 0.45) / 0.05, 0), 1);
        var arriving = t * t * (3 - 2 * t);
        if (arriving > 0.01) blooms.Add((origin + 0.5, arriving));
        if (_symmetryDraining)
        {
            var draining = Math.Max(0, 1 - p / Math.Max(cometLength * 0.9, 0.01));
            if (draining > 0.01) blooms.Add((origin, draining));
        }
        return blooms;
    }

    /// <summary>A bloom at the merge point that swells as the mirrored heads arrive and fades while their tails drain into it.</summary>
    private void DrawMergeGlow(SKCanvas canvas, float w, float h, double beat, double opacity, AppState state)
    {
        var blooms = SymmetryBlooms(state.CometLength);
        if (blooms.Count == 0) return;

        using var path = EdgePath(w, h, 0);
        using var measure = new SKPathMeasure(path, false);
        using var segment = new SKPath();
        var reach = 0.01 + 0.008 * Math.Min(beat, 1.5);
        var blur = Blur(state.GlowSpread * (0.5 + 0.3 * beat));
        foreach (var bloom in blooms)
        {
            using var paint = StrokePaint(state.Thickness * (1 + 0.6 * beat), Col(CometHeadColor, opacity * bloom.Glow), SKStrokeCap.Round);
            paint.BlendMode = SKBlendMode.Plus;
            paint.ImageFilter = blur;
            segment.Rewind();
            // AddSegment wraps, so a bloom at top-center (0) spans both sides of the path's start.
            AddSegment(measure, bloom.Point - reach, bloom.Point + reach, segment);
            canvas.DrawPath(segment, paint);
        }
    }

    // ---- Chromatic impact ----

    /// <summary>
    /// Heavy-impact channel split: the crisp rim redrawn as a red copy pushed outward and a cyan copy pulled
    /// inward, each keeping the rim's own alpha. Driven straight off the bass envelope, so it snaps back as
    /// the hit decays.
    /// </summary>
    private void DrawChromaticSplit(SKCanvas canvas, double inset, double amount, double opacity, Action<SKCanvas, double> stroke)
    {
        if (amount <= 0.01) return;
        var shift = 3 + 7 * amount;
        var channels = new (double Inset, SKColor Tint)[]
        {
            (inset - shift * 0.6, new SKColor(255, 0, 0)),
            (inset + shift, new SKColor(0, 255, 255)),
        };
        foreach (var channel in channels)
        {
            using var tint = SKColorFilter.CreateBlendMode(channel.Tint, SKBlendMode.SrcIn); // pure tint, keeping the stroke's alpha
            using var layerPaint = new SKPaint
            {
                BlendMode = SKBlendMode.Plus,
                Color = new SKColor(255, 255, 255, A(Math.Min(1, opacity * amount * 1.1))),
                ColorFilter = tint,
            };
            layerPaint.ImageFilter = Blur(2.5);
            canvas.SaveLayer(layerPaint);
            stroke(canvas, channel.Inset);
            canvas.Restore();
        }
    }

    // ---- Kinetic physics ----

    private void UpdateKinetics(double dt, (double Bass, double Vocal) levels, bool spawning, bool merged, AppState state)
    {
        _bassCooldown -= dt;
        _vocalCooldown -= dt;

        if (spawning && _nodes.Length > 0)
        {
            var style = state.AnimationStyle;
            var hot = HotNodes(style, state.CometLength);

            // Bass transient: the envelope jumps well above its recent average.
            var bassRise = levels.Bass - _bassAverage;
            if (_bassCooldown <= 0 && levels.Bass > 0.45 && bassRise > 0.16)
            {
                var hit = Math.Min(Math.Max(bassRise * 2.2, 0.3), 1);
                var kick = hit * state.Reactivity * 1_100 * (0.6 + state.Thickness / 80);
                foreach (var index in hot) Pluck(index, kick, 7);
                // A smaller thump across the whole bezel so every edge flexes a little.
                for (var i = 0; i < _displacementVelocity.Length; i++) _displacementVelocity[i] += kick * 0.2;
                _stringAwake = true;
                // Sparks are all there is in Sparks Only, so each hit throws a fuller burst.
                var count = style == AnimationStyle.SparksOnly
                    ? 6 + (int)Math.Round(hit * 8, MidpointRounding.AwayFromZero)
                    : 3 + (int)Math.Round(hit * 5, MidpointRounding.AwayFromZero);
                SpawnSparks(count, hot, _primary.Lerp(RgbColor.White, 0.3), hit);
                _shake = Math.Min(_shake + hit * hit * state.Reactivity * (levels.Bass > 0.7 ? 1 : 0.35), 1.5);
                _bassCooldown = 0.14;
            }

            // Vocal transient: a burst of secondary-colored sparks, no bounce. Sparks Only reacts to hard bass hits alone.
            var vocalRise = levels.Vocal - _vocalAverage;
            if (style != AnimationStyle.SparksOnly && _vocalCooldown <= 0 && levels.Vocal > 0.5 && vocalRise > 0.2)
            {
                var hit = Math.Min(Math.Max(vocalRise * 2, 0.3), 1);
                SpawnSparks(3 + (int)Math.Round(hit * 2, MidpointRounding.AwayFromZero), hot, _secondary.Lerp(RgbColor.White, 0.2), hit * 0.8);
                _vocalCooldown = 0.3;
            }

            // Symmetry: the mirrored heads colliding flick the string and throw sparks at the merge point,
            // which (after the flip in Draw) is the origin of the new pass.
            if (merged)
            {
                var mergePoint = NodeIndex(SymmetryOrigin(_symmetryTopToBottom));
                Pluck(mergePoint, 450 * state.Reactivity, 6);
                _stringAwake = true;
                SpawnSparks(5, new List<int> { mergePoint }, CometHeadColor, 0.6);
            }
        }

        _bassAverage += (levels.Bass - _bassAverage) * (1 - Math.Exp(-dt * 3));
        _vocalAverage += (levels.Vocal - _vocalAverage) * (1 - Math.Exp(-dt * 2));
        _shake *= Math.Exp(-dt * 9);
        StepString(dt);
        StepSparks(dt);
    }

    /// <summary>Nodes at the brightest points on the rim, where hits pluck the string and sparks spawn.</summary>
    private List<int> HotNodes(AnimationStyle style, double cometLength)
    {
        switch (style)
        {
            case AnimationStyle.Breathing:
            {
                // Gradient stops [p, s, p, s, p]: primary sits at +0/+pi, secondary at +pi/2/+3pi/2.
                var baseAngle = _primary.Luminance >= _secondary.Luminance ? _angle : _angle + Math.PI / 2;
                return new List<int> { NodeIndexNearestAngle(baseAngle), NodeIndexNearestAngle(baseAngle + Math.PI) };
            }
            case AnimationStyle.Chasing:
                return new List<int> { NodeIndex(_chasePosition), NodeIndex(_chasePosition + 0.5) };
            case AnimationStyle.Symmetry:
            {
                // The current pair's heads, plus any merge point still blooming, so a hard bass hit during a
                // merge bursts right out of it.
                var points = SymmetryComets(_symmetryProgress, _symmetryTopToBottom).Select(c => c.Head).ToList();
                points.AddRange(SymmetryBlooms(cometLength).Where(b => b.Glow > 0.3).Select(b => b.Point));
                return points.Select(NodeIndex).ToList();
            }
            default:
                return Enumerable.Range(0, 3).Select(_ => _rng.Next(_nodes.Length)).ToList();
        }
    }

    /// <summary>Nodes are spaced evenly by arc length from top-center, so a perimeter fraction maps straight to one.</summary>
    private int NodeIndex(double t)
    {
        var n = _nodes.Length;
        return (int)((t - Math.Floor(t)) * n) % n;
    }

    private int NodeIndexNearestAngle(double target)
    {
        var best = 0;
        var bestDistance = double.PositiveInfinity;
        for (var index = 0; index < _nodes.Length; index++)
        {
            var delta = Math.Abs(_nodes[index].Angle - target) % (2 * Math.PI);
            if (delta > Math.PI) delta = 2 * Math.PI - delta;
            if (delta < bestDistance) { bestDistance = delta; best = index; }
        }
        return best;
    }

    /// <summary>Gaussian inward velocity kick centered on one node, like plucking a string.</summary>
    private void Pluck(int center, double velocity, double width)
    {
        var n = _displacementVelocity.Length;
        for (var i = 0; i < n; i++)
        {
            var distance = Math.Abs(i - center);
            distance = Math.Min(distance, n - distance);
            _displacementVelocity[i] += velocity * Math.Exp(-(double)(distance * distance) / (2 * width * width));
        }
    }

    /// <summary>Integrates the closed string with semi-implicit Euler in small substeps for stability.</summary>
    private void StepString(double dt)
    {
        if (!_stringAwake || dt <= 0) return;
        var d = (double[])_displacement.Clone();
        var v = (double[])_displacementVelocity.Clone();
        var n = d.Length;
        var steps = Math.Max(1, (int)Math.Ceiling(dt / 0.005));
        var h = dt / steps;
        for (var step = 0; step < steps; step++)
        {
            for (var i = 0; i < n; i++)
            {
                var left = d[i == 0 ? n - 1 : i - 1];
                var right = d[i == n - 1 ? 0 : i + 1];
                var acceleration = StringTension * (left + right - 2 * d[i]) - StringStiffness * d[i] - StringDamping * v[i];
                v[i] += acceleration * h;
            }
            for (var i = 0; i < n; i++) d[i] = Math.Min(Math.Max(d[i] + v[i] * h, -30), 90);
        }

        double maxDisplacement = 0, maxVelocity = 0;
        for (var i = 0; i < n; i++)
        {
            maxDisplacement = Math.Max(maxDisplacement, Math.Abs(d[i]));
            maxVelocity = Math.Max(maxVelocity, Math.Abs(v[i]));
        }
        if (maxDisplacement < 0.05 && maxVelocity < 0.5)
        {
            // Settled: snap to rest so drawing goes back to the exact analytic bezel paths.
            Array.Clear(d, 0, n);
            Array.Clear(v, 0, n);
            _stringAwake = false;
        }
        _displacement = d;
        _displacementVelocity = v;
    }

    private void SpawnSparks(int count, List<int> hot, RgbColor color, double energy)
    {
        if (_nodes.Length == 0 || hot.Count == 0) return;
        var n = _nodes.Length;
        for (var k = 0; k < count; k++)
        {
            var index = ((hot[k % hot.Count] + _rng.Next(-6, 7)) % n + n) % n;
            var node = _nodes[index];
            var depth = Math.Max(_displacement[index], 0) + Range(2, 10);
            var speed = Range(320, 900) * (0.6 + 0.4 * energy);
            var drift = Range(-90, 90);
            _sparks.Add(new Spark
            {
                X = node.Point.X + node.Normal.X * depth,
                Y = node.Point.Y + node.Normal.Y * depth,
                // Mostly straight inward, with some sideways drift along the edge.
                Vx = node.Normal.X * speed - node.Normal.Y * drift,
                Vy = node.Normal.Y * speed + node.Normal.X * drift,
                Age = 0,
                Life = Range(0.8, 1.25),
                Size = Range(1.6, 3.6),
                Color = color,
            });
        }
        if (_sparks.Count > MaxSparks) _sparks.RemoveRange(0, _sparks.Count - MaxSparks);
    }

    private double Range(double lo, double hi) => lo + _rng.NextDouble() * (hi - lo);

    private void StepSparks(double dt)
    {
        if (_sparks.Count == 0) return;
        var drag = Math.Exp(-dt * 2.6);
        for (var i = 0; i < _sparks.Count; i++)
        {
            var s = _sparks[i];
            s.Vx *= drag;
            s.Vy *= drag;
            s.X += s.Vx * dt;
            s.Y += s.Vy * dt;
            s.Age += dt;
            _sparks[i] = s;
        }
        _sparks.RemoveAll(s => s.Age >= s.Life);
    }

    private static double SparkAlpha(in Spark s) => Math.Pow(Math.Max(1 - s.Age / s.Life, 0), 1.5);

    /// <summary>Sparks as a constellation: faint links between nearby sparks, soft glowing halos, bright cores.</summary>
    private void DrawSparks(SKCanvas canvas, double opacity)
    {
        if (_sparks.Count == 0) return;

        using (var links = StrokePaint(0.7, SKColors.White))
        {
            links.BlendMode = SKBlendMode.Plus;
            for (var i = 0; i < _sparks.Count; i++)
            {
                var a = _sparks[i];
                var alphaA = SparkAlpha(a);
                for (var j = i + 1; j < _sparks.Count; j++)
                {
                    var b = _sparks[j];
                    var dx = a.X - b.X;
                    var dy = a.Y - b.Y;
                    var distance = Math.Sqrt(dx * dx + dy * dy);
                    if (distance >= SparkLinkDistance) continue;
                    var alpha = Math.Min(alphaA, SparkAlpha(b)) * (1 - distance / SparkLinkDistance) * 0.55 * opacity;
                    links.Color = Col(a.Color, alpha);
                    canvas.DrawLine((float)a.X, (float)a.Y, (float)b.X, (float)b.Y, links);
                }
            }
        }

        // One blurred layer for all halos instead of a blur per spark.
        using (var layerPaint = new SKPaint { BlendMode = SKBlendMode.Plus })
        {
            layerPaint.ImageFilter = Blur(6);
            canvas.SaveLayer(layerPaint);
            using var fill = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Fill };
            foreach (var spark in _sparks)
            {
                var alpha = SparkAlpha(spark);
                var radius = spark.Size * 3.2 * (0.6 + 0.4 * alpha);
                fill.Color = Col(spark.Color, alpha * 0.85 * opacity);
                canvas.DrawCircle((float)spark.X, (float)spark.Y, (float)radius, fill);
            }
            canvas.Restore();
        }

        using (var cores = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Fill, BlendMode = SKBlendMode.Plus })
        {
            foreach (var spark in _sparks)
            {
                var alpha = SparkAlpha(spark);
                var radius = spark.Size * (0.6 + 0.4 * alpha);
                cores.Color = Col(spark.Color.Lerp(RgbColor.White, 0.6), alpha * opacity);
                canvas.DrawCircle((float)spark.X, (float)spark.Y, (float)radius, cores);
            }
        }
    }

    // ---- Edge geometry ----

    /// <summary>
    /// The bezel path at <paramref name="inset"/>, bent by the string displacement. While the string is at rest
    /// this is the exact analytic bezel (a rounded rectangle). Every variant starts at top-center and runs
    /// clockwise, so perimeter fractions line up with the string nodes for trimming comets.
    /// </summary>
    private SKPath EdgePath(float w, float h, double inset)
    {
        if (!_stringAwake || _nodes.Length != NodeCount || _geometrySize != (w, h) || _samples.Length == 0)
            return BezelPath(w, h, (float)inset);

        var path = new SKPath();
        for (var k = 0; k < _samples.Length; k++)
        {
            var sample = _samples[k];
            var offset = inset + DisplacementAtNode(sample.Node);
            var x = (float)(sample.Point.X + sample.Normal.X * offset);
            var y = (float)(sample.Point.Y + sample.Normal.Y * offset);
            if (k == 0) path.MoveTo(x, y); else path.LineTo(x, y);
        }
        path.Close();
        return path;
    }

    /// <summary>Catmull-Rom interpolation of the closed string at fractional node position t.</summary>
    private double DisplacementAtNode(double t)
    {
        var n = _displacement.Length;
        var i = (int)Math.Floor(t);
        var f = t - i;
        double D(int k) => _displacement[((k % n) + n) % n];
        double p0 = D(i - 1), p1 = D(i), p2 = D(i + 1), p3 = D(i + 2);
        return p1 + 0.5 * f * (p2 - p0 + f * (2 * p0 - 5 * p1 + 4 * p2 - p3 + f * (3 * (p1 - p2) + p3 - p0)));
    }

    /// <summary>
    /// Analytic bezel at <paramref name="inset"/>: clockwise from top-center. Screen corners keep a constant
    /// radius like the original inset RoundedRectangle.
    /// </summary>
    private static SKPath BezelPath(float w, float h, float inset)
    {
        var i = inset;
        var start = new SKPoint(w / 2, i);
        var corners = new SKPoint[]
        {
            new(w - i, i),
            new(w - i, h - i),
            new(i, h - i),
            new(i, i),
        };
        var path = new SKPath();
        path.MoveTo(start);
        for (var k = 0; k < corners.Length; k++)
        {
            var next = k + 1 < corners.Length ? corners[k + 1] : start;
            path.ArcTo(corners[k].X, corners[k].Y, next.X, next.Y, CornerRadius);
        }
        path.LineTo(start);
        path.Close();
        return path;
    }

    /// <summary>
    /// Lays out the string nodes evenly by arc length around the bezel outline, plus the dense draw samples.
    /// Recomputed only when the overlay changes size, which also resets in-flight physics.
    /// </summary>
    private void PrepareGeometry(float w, float h)
    {
        if ((w, h) == _geometrySize || w <= 2 * CornerRadius || h <= 2 * CornerRadius) return;
        _geometrySize = (w, h);

        var outline = new BezelOutline(w, h, CornerRadius);
        _nodes = Enumerable.Range(0, NodeCount).Select(i =>
        {
            var (point, normal) = outline.Sample(i / (double)NodeCount * outline.Length);
            return new EdgeNode(point, normal, Math.Atan2(point.Y - h / 2, point.X - w / 2));
        }).ToArray();
        var sampleCount = Math.Max(64, (int)(outline.Length / SampleSpacing));
        _samples = Enumerable.Range(0, sampleCount).Select(i =>
        {
            var fraction = i / (double)sampleCount;
            var (point, normal) = outline.Sample(fraction * outline.Length);
            return new OutlineSample(point, normal, fraction * NodeCount);
        }).ToArray();
        _displacement = new double[NodeCount];
        _displacementVelocity = new double[NodeCount];
        _stringAwake = false;
        _sparks.Clear();
    }
}
