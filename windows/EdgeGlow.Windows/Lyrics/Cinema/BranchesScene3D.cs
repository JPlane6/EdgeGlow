using System;
using System.Collections.Generic;
using System.Numerics;

namespace EdgeGlow.Lyrics;

/// <summary>
/// Branches: a 3D neural tree. Each word sprouts from the previous one along a glowing cubic Bezier spline that
/// twists through depth and forks into twigs. The camera rides the growing tip; sung words stay along the lit branch.
/// </summary>
public sealed class BranchesScene3D : Scene3D
{
    private readonly List<Vector3> _nodes = new(), _dirs = new();
    private readonly List<float> _lens = new();

    public BranchesScene3D(bool icons) : base(icons, 7) { }
    protected override void Reset2() { _nodes.Clear(); _dirs.Clear(); _lens.Clear(); }

    private void EnsureNodes(int index)
    {
        while (_nodes.Count <= index)
        {
            var i = _nodes.Count;
            if (i == 0) { _nodes.Add(Vector3.Zero); _dirs.Add(new Vector3(0, 0.15f, 1)); _lens.Add(0); continue; }
            var prev = _dirs[i - 1];
            var wobble = new Vector3((float)(CanvasKit.Hash(i * 11 + 3) - 0.5), (float)(CanvasKit.Hash(i * 19 + 7) - 0.5) * 1.6f, 0.15f) * 1.5f;
            var d = Vector3.Normalize(prev + wobble);
            d.Y -= _nodes[i - 1].Y * 0.0006f;
            d = Vector3.Normalize(d);
            var len = (float)(230 + 100 * CanvasKit.Hash(i * 17 + 9));
            _nodes.Add(_nodes[i - 1] + d * len);
            _dirs.Add(d); _lens.Add(len);
        }
    }

    private readonly record struct Cubic(Vector3 P0, Vector3 C1, Vector3 C2, Vector3 P1)
    {
        public Vector3 Point(float t)
        {
            var u = 1 - t;
            return P0 * (u * u * u) + C1 * (3 * u * u * t) + C2 * (3 * u * t * t) + P1 * (t * t * t);
        }
    }

    private Cubic Segment(int i)
    {
        Vector3 p0 = _nodes[i - 1], p1 = _nodes[i]; var len = _lens[i];
        return new Cubic(p0, p0 + _dirs[i - 1] * len * 0.5f, p1 - _dirs[i] * len * 0.5f, p1);
    }

    private static double Growth(int i, List<TimedWord> words, double pos)
    {
        var end = words[i].Start;
        var begin = Math.Max(words[i - 1].Start, end - 1.3);
        if (end <= begin) return pos >= end ? 1 : 0;
        return CanvasKit.Smoothstep((pos - begin) / (end - begin));
    }

    private (int Index, Vector3 Point) Tip(SceneInput input)
    {
        var words = input.Lyrics.Words;
        var g = Math.Min(words.Count - 1, (input.ActiveWord ?? -1) + 1);
        if (g < 1 || g >= _nodes.Count) return (0, _nodes.Count > 0 ? _nodes[0] : Vector3.Zero);
        return (g, Segment(g).Point((float)Growth(g, words, input.Pos)));
    }

    private SemanticKineticEngine.Anchor? Anchor(int i) =>
        i >= 0 && i < _nodes.Count ? new SemanticKineticEngine.Anchor(_nodes[i] + new Vector3(0, 70, 0), 90, 78) : null;

    public override void Update(SceneInput input, double dt)
    {
        var words = input.Lyrics.Words;
        if (words.Count == 0) return;
        var a = input.ActiveWord ?? -1;
        EnsureNodes(Math.Min(words.Count - 1, a + 14));
        var (g, tipPoint) = Tip(input);
        var d = Vector3d.From(_dirs[Math.Min(g, _dirs.Count - 1)]);
        var target = Vector3d.From(tipPoint);
        var side = Vector3d.Cross(d, new Vector3d(0, 1, 0)).Normalized();
        var scale = Math.Max(0.5, input.Theme.Scale);
        var desired = target - d * (240 / scale) + side * ((1100 + 140 * Math.Sin(input.Time * 0.17)) / scale) + new Vector3d(0, 160, 0);
        var next = g + 1 < _nodes.Count ? Vector3d.From(_nodes[g + 1]) : target;
        Camera.Update(dt, desired, target, next, 0.3, 0.08 * Math.Sin(input.Time * 0.35), input.Bass, input.Velocity);
        MarkPrimed();
        Engine.Update(input, dt, Anchor, Camera);
    }

    public override void Build(SceneInput input, DrawList list, in CameraFrame frame)
    {
        var words = input.Lyrics.Words;
        if (words.Count == 0 || _nodes.Count <= 1) return;
        var hl = Highlight(input); var sec = Secondary(input);
        var a = input.ActiveWord ?? -1;
        var (g, tipPoint) = Tip(input);
        var right = frame.Right; var up = frame.Up;
        int lo = Math.Max(1, a - 11), hi = Math.Min(words.Count - 1, g);

        var focalPoint = a >= 0 ? (_nodes[a] + tipPoint) * 0.5f + up * 40 : tipPoint;
        list.Sprite(DrawKind.Plume, focalPoint, 160, new Vector4(0.03f, 0.03f, 0.047f, 1), 0.78f, 2.2f, DrawLayer.Back, frame);

        if (a >= 0) for (var i = Math.Max(0, a - 9); i <= a; i++) DrawTwigs(i, input, list, frame, hl, sec);

        if (lo <= hi)
            for (var i = lo; i <= hi; i++)
            {
                var growthValue = (float)Growth(i, words, input.Pos);
                if (growthValue <= 0.002f) continue;
                var c = Segment(i);
                var live = i == g && growthValue < 0.999f;
                var recency = MathF.Exp(-Math.Max(0, a - i) / 3.5f);
                const int steps = 14;
                var prev = c.P0;
                for (var s = 1; s <= steps; s++)
                {
                    var t = (float)s / steps * growthValue;
                    var q = c.Point(t);
                    var px = PerPixel(frame.DepthOf((prev + q) * 0.5f), frame);
                    var u = (float)s / steps;
                    var col = hl + (sec - hl) * u;
                    var width = (live ? 8f : 2.4f + 4.0f * recency) * px;
                    list.Ribbon(prev, q, width * 2.4f, new Vector4(0, 0, 0, live ? 0.65f : 0.5f), 0, DrawLayer.Back, frame);
                    RibbonU(list, prev, q, width, new Vector4(col.X, col.Y, col.Z, live ? 1 : 0.4f + 0.55f * recency), live ? 1.4f : 0.6f, frame);
                    prev = q;
                }
            }
        list.Sprite(DrawKind.Glow, tipPoint, 38 + 14 * (float)input.Bass, new Vector4(hl.X, hl.Y, hl.Z, 0.95f), 2, 0, DrawLayer.Glow, frame);
        list.Sprite(DrawKind.Glow, tipPoint, 9, new Vector4(1, 1, 1, 1), 1.6f, 0, DrawLayer.Glow, frame);

        if (a >= 0)
            for (var i = Math.Max(0, a - 10); i <= a; i++)
            {
                var p = _nodes[i];
                var isActive = i == a;
                var age = (float)Math.Max(0, input.Pos - words[i].Start);
                var dof = frame.Dof(frame.DepthOf(p), 1500);
                list.Sprite(DrawKind.Glow, p, isActive ? 60 : 28, new Vector4(sec.X, sec.Y, sec.Z, isActive ? 0.8f : 0.45f), 2, 0, DrawLayer.Glow, frame);
                list.Sprite(DrawKind.Glow, p, isActive ? 10 : 6, new Vector4(1, 1, 1, 0.95f), 1.6f, 0, DrawLayer.Glow, frame);
                if (isActive || age < 1.2f) list.Sprite(DrawKind.Flare, p, 60 + 120 * MathF.Exp(-age * 3), new Vector4(hl.X, hl.Y, hl.Z, 0.7f), 0, 0, DrawLayer.Glow, frame);
                var height = isActive ? 80f : 50f;
                var sideSign = i % 2 == 0 ? -1f : 1f;
                var labelCenter = p + up * (isActive ? 86 : sideSign * 56) + right * (isActive ? 0 : 40);
                var color = new Vector4(1, 1, 1, isActive ? 1 : i < a ? 0.42f : 0.18f);
                color.W *= dof.Fade;
                var mod = Engine.WordMod(i, input, isActive);
                list.Sprite(DrawKind.Plume, labelCenter, height * 0.8f, new Vector4(0.03f, 0.03f, 0.047f, 1), isActive ? 0.6f : 0.3f, 2.4f, DrawLayer.Back, frame);
                DrawWord(words[i].Text, labelCenter, height, right, up, color, mod, input, list, frame, blur: isActive || i < a ? 0 : 1.5f + Math.Min(2.5f, dof.Blur));
            }
        if (g >= 1 && g < words.Count && g > a)
        {
            var p = _nodes[g];
            var t = (float)Growth(g, words, input.Pos);
            DrawWord(words[g].Text, p + up * 64, 40, right, up, new Vector4(1, 1, 1, 0.3f + 0.4f * t), WordMod.Identity, input, list, frame, blur: 0.1f);
        }
        Engine.Draw(list, frame);
    }

    private void DrawTwigs(int i, SceneInput input, DrawList list, in CameraFrame frame, Vector4 hl, Vector4 sec)
    {
        var words = input.Lyrics.Words;
        var age = (float)(input.Pos - words[i].Start);
        var grow = (float)CanvasKit.Smoothstep(age / 0.9);
        if (grow <= 0.01f) return;
        var o = _nodes[i];
        var recency = MathF.Exp(-Math.Max(0, (input.ActiveWord ?? 0) - i) / 4f);
        for (var k = 0; k < 2; k++)
        {
            var side = (i + k) % 2 == 0 ? 1f : -1f;
            var perp1 = Vector3.Normalize(Vector3.Cross(_dirs[i], Vector3.UnitY));
            var perp2 = Vector3.Cross(_dirs[i], perp1);
            var ang = (float)CanvasKit.Hash(i * 19 + k) * 2 * MathF.PI;
            var outward = Vector3.Normalize(perp1 * MathF.Cos(ang) + perp2 * MathF.Sin(ang) + _dirs[i] * 0.5f * side);
            var len = (130 + 100 * Hash(i * 23 + k * 3)) * grow;
            var mid = o + outward * len * 0.5f + perp2 * 30;
            var end = o + outward * len;
            var prev = o;
            for (var s = 1; s <= 6; s++)
            {
                var t = s / 6f; var u = 1 - t;
                var q = o * (u * u) + mid * (2 * u * t) + end * (t * t);
                var px = PerPixel(frame.DepthOf(q), frame);
                RibbonU(list, prev, q, 2.2f * px, new Vector4(sec.X, sec.Y, sec.Z, 0.4f + 0.4f * recency), 0.4f, frame);
                prev = q;
            }
            list.Sprite(DrawKind.Glow, end, 12, new Vector4(sec.X, sec.Y, sec.Z, 0.2f + 0.5f * recency), 2, 0, DrawLayer.Glow, frame);
        }
    }
}
