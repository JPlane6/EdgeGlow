using System;
using System.Numerics;

namespace EdgeGlow.Lyrics;

/// <summary>
/// Orbital Web 3D: the polar spoke-and-ring web as a holographic gyroscope disc. The disc turns so the active spoke
/// faces the viewer, banks toward the sung (spoke, ring) intersection, and bass transients ripple outward through the rings.
/// </summary>
public sealed class OrbitalWebScene3D : Scene3D
{
    private readonly OrbitalGeometry _geo = new(8, 4, 300, 260);
    private double _rotation; private bool _rotationPrimed;
    private double _lastBass, _rippleClock = -10;

    public OrbitalWebScene3D(bool icons) : base(icons, 7) { }
    protected override void Reset2() { _rotationPrimed = false; _rippleClock = -10; }

    private Vector3 NodePoint(int i)
    {
        var s = _geo.Slot(i);
        var p = _geo.Point(s.Spoke, s.Ring, _rotation);
        return new Vector3((float)p.X, 0, (float)p.Z);
    }

    private SemanticKineticEngine.Anchor? Anchor(int i) => new(NodePoint(i) + new Vector3(0, 34, 0), 70, 56);

    public override void Update(SceneInput input, double dt)
    {
        var words = input.Lyrics.Words;
        if (words.Count == 0) return;
        var a = input.ActiveWord ?? 0;
        var s = _geo.Slot(a);
        var wanted = _geo.RotationFacing(s.Spoke);
        if (!_rotationPrimed) { _rotation = wanted; _rotationPrimed = true; }
        var delta = (wanted - _rotation) % (2 * Math.PI);
        if (delta > Math.PI) delta -= 2 * Math.PI; else if (delta < -Math.PI) delta += 2 * Math.PI;
        _rotation += delta * (1 - Math.Exp(-dt * 2.6));

        if (input.Bass > 0.55 && _lastBass <= 0.55 && input.Time - _rippleClock > 0.25) _rippleClock = input.Time;
        _lastBass = input.Bass;

        var scale = Math.Max(0.5, input.Theme.Scale);
        var node = Vector3d.From(NodePoint(a));
        var tilt = 0.50 + 0.06 * Math.Sin(input.Time * 0.33);
        var dist = 1500 / scale;
        var desired = new Vector3d(node.X * 0.35, dist * Math.Sin(tilt), dist * Math.Cos(tilt));
        var progress = input.ActiveWord is int aw ? CanvasKit.Smoothstep(input.Progress(words[aw])) : 0;
        var next = a + 1 < words.Count ? Vector3d.From(NodePoint(a + 1)) : node;
        Camera.Update(dt, desired, node * 0.55, next * 0.55, progress * 0.5, Math.Clamp(-node.X / 1400, -0.3, 0.3), input.Bass, input.Velocity);
        MarkPrimed();
        Engine.Update(input, dt, Anchor, Camera);
    }

    public override void Build(SceneInput input, DrawList list, in CameraFrame frame)
    {
        var words = input.Lyrics.Words;
        if (words.Count == 0) return;
        var hl = Highlight(input); var sec = Secondary(input);
        var activeIndex = input.ActiveWord;
        var a = activeIndex ?? 0;
        int lo = Math.Max(0, a - 12), hi = Math.Min(words.Count - 1, a + 12);
        var t = (float)input.Time;
        var rippleAge = (float)(input.Time - _rippleClock);

        list.Sprite(DrawKind.Plume, new Vector3(0, -6, 0), (float)_geo.OuterRadius * 0.62f, new Vector4(0.03f, 0.03f, 0.047f, 1), 0.5f, 1f, DrawLayer.Back, frame);

        bool Lit(Func<int, bool> match)
        {
            if (activeIndex == null) return false;
            for (var i = lo; i <= hi; i++) if (match(i) && input.Pos >= words[i].Start) return true;
            return false;
        }

        for (var sp = 0; sp < _geo.Spokes; sp++)
        {
            var ang = _geo.Angle(sp) + _rotation;
            var dir = new Vector3((float)Math.Cos(ang), 0, (float)Math.Sin(ang));
            var lit = Lit(i => _geo.Slot(i).Spoke == sp);
            Vector3 from = dir * (float)(_geo.InnerRadius * 0.4), to = dir * (float)_geo.OuterRadius;
            var px = PerPixel(frame.DepthOf((from + to) * 0.5f), frame);
            var c = lit ? new Vector4(hl.X, hl.Y, hl.Z, 0.8f) : new Vector4(1, 1, 1, 0.42f);
            RibbonU(list, from, to, (lit ? 2.0f : 1.4f) * px, c, lit ? 0.7f : 0.2f, frame);
        }

        for (var r = 0; r < _geo.Rings; r++)
        {
            var radius = (float)_geo.Radius(r);
            var lit = Lit(i => _geo.Slot(i).Ring == r);
            var wave = Math.Max(0, 1 - Math.Abs(rippleAge * 1.6f - r) * 1.3f);
            var lift = 26 * wave * (float)Math.Max(0.2, input.Bass);
            Vector3? prev = null;
            for (var k = 0; k <= 72; k++)
            {
                var ang = k / 72f * 2 * MathF.PI;
                var p = new Vector3(MathF.Cos(ang) * radius, lift * MathF.Sin(ang * 4 + t), MathF.Sin(ang) * radius);
                if (prev is { } q)
                {
                    var px = PerPixel(frame.DepthOf((p + q) * 0.5f), frame);
                    var c = lit ? new Vector4(sec.X, sec.Y, sec.Z, 0.7f + 0.3f * wave) : new Vector4(1, 1, 1, 0.38f + 0.4f * wave);
                    RibbonU(list, q, p, (lit ? 2.0f : 1.4f) * px, c, 0.2f + wave, frame);
                }
                prev = p;
            }
        }

        for (var i = Math.Max(1, lo); i <= hi && i < words.Count; i++)
        {
            var from = i - 1;
            if (activeIndex == null || from > a) continue;
            var traced = from < a ? 1.0 : CanvasKit.Smoothstep(input.Progress(words[a]));
            Vector3 p0 = NodePoint(from), p1 = NodePoint(i);
            var end = p0 + (p1 - p0) * (float)traced;
            var px = PerPixel(frame.DepthOf((p0 + end) * 0.5f), frame);
            var live = from == a;
            RibbonU(list, p0, end, (live ? 2.6f : 1.4f) * px, new Vector4(hl.X, hl.Y, hl.Z, live ? 0.95f : 0.45f), live ? 1.2f : 0.4f, frame);
            if (live) list.Sprite(DrawKind.Glow, end, 24, new Vector4(hl.X, hl.Y, hl.Z, 0.95f), 2, 0, DrawLayer.Glow, frame);
        }

        var right = frame.Right; var up = frame.Up;
        for (var i = lo; i <= hi; i++)
        {
            var p = NodePoint(i);
            var isActive = i == a && activeIndex != null;
            var past = activeIndex != null && i < a;
            var age = (float)Math.Max(0, input.Pos - words[i].Start);
            var dof = frame.Dof(frame.DepthOf(p), 1500);
            var nodeAlpha = isActive ? 1f : past ? 0.4f : 0.2f;
            list.Sprite(DrawKind.Glow, p, (isActive ? 56 : 30) * (1 + 0.4f * (float)input.Bass), new Vector4(hl.X, hl.Y, hl.Z, nodeAlpha * 0.7f), 2, 0, DrawLayer.Glow, frame);
            list.Sprite(DrawKind.Glow, p, 9, new Vector4(1, 1, 1, Math.Min(1, nodeAlpha * 1.6f)), 1.6f, 0, DrawLayer.Glow, frame);
            if (isActive || (past && age < 1.4f))
            {
                var f = MathF.Exp(-age * 3);
                list.Sprite(DrawKind.Flare, p, 70 + 150 * f, new Vector4(hl.X, hl.Y, hl.Z, Math.Min(1, 0.4f + f)), 0, 0, DrawLayer.Glow, frame);
            }
            var mod = Engine.WordMod(i, input, isActive);
            var height = isActive ? 84f : 52f;
            var center = p + up * (isActive ? 62 : 44);
            var color = new Vector4(1, 1, 1, isActive ? 1 : past ? 0.42f : 0.18f);
            color.W *= dof.Fade;
            list.Sprite(DrawKind.Plume, center, height * 0.8f, new Vector4(0.03f, 0.03f, 0.047f, 1), isActive ? 0.6f : 0.3f, 2.4f, DrawLayer.Back, frame);
            DrawWord(words[i].Text, center, height, right, up, color, mod, input, list, frame, blur: isActive || past ? 0 : 1.5f + Math.Min(2.5f, dof.Blur));
        }
        Engine.Draw(list, frame);
    }
}
