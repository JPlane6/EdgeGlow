using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;

namespace EdgeGlow.Lyrics;

/// <summary>
/// Constellation (and Constellation 3D): words are glowing star coordinates along a winding flight path through a
/// parallax starfield. Filaments trace from word to word as they are sung, with faint triangulated struts, and the
/// camera flies the path. The 3D variant adds deep parallax star shells, harder banking and bass-breathing halos.
/// </summary>
public sealed class ConstellationScene3D : Scene3D
{
    private readonly bool _deep;
    private readonly List<Vector3> _nodes = new(), _dirs = new();
    private readonly List<double> _yaws = new(), _pitches = new();

    public ConstellationScene3D(bool icons, bool deep = false) : base(icons, deep ? 17 : 7) { _deep = deep; }
    protected override void Reset2() { _nodes.Clear(); _dirs.Clear(); _yaws.Clear(); _pitches.Clear(); }

    private void EnsureNodes(int index, List<TimedWord> words)
    {
        while (_nodes.Count <= index)
        {
            var i = _nodes.Count;
            if (i == 0) { _nodes.Add(Vector3.Zero); _dirs.Add(new Vector3(0, 0, 1)); _yaws.Add(0); _pitches.Add(0); continue; }
            var newLine = words[i].Line != words[i - 1].Line;
            var yaw = _yaws[i - 1] + (CanvasKit.Hash(i * 7 + 1) - 0.5) * (newLine ? 1.6 : 0.9);
            yaw -= yaw * 0.14;
            var pitch = _pitches[i - 1] + (CanvasKit.Hash(i * 13 + 5) - 0.5) * 1.5;
            pitch -= pitch * 0.12;
            yaw = Math.Clamp(yaw, -1.2, 1.2); pitch = Math.Clamp(pitch, -0.95, 0.95);
            var d = new Vector3((float)(Math.Sin(yaw) * Math.Cos(pitch)), (float)Math.Sin(pitch), (float)(Math.Cos(yaw) * Math.Cos(pitch)));
            var len = (float)(250 + 120 * CanvasKit.Hash(i * 17 + 3) + (newLine ? 130 : 0));
            _nodes.Add(_nodes[i - 1] + d * len);
            _dirs.Add(d); _yaws.Add(yaw); _pitches.Add(pitch);
        }
    }

    private SemanticKineticEngine.Anchor? Anchor(int i) =>
        i >= 0 && i < _nodes.Count ? new SemanticKineticEngine.Anchor(_nodes[i] + new Vector3(0, 70, 0), 90, 78) : null;

    public override void Update(SceneInput input, double dt)
    {
        var words = input.Lyrics.Words;
        if (words.Count == 0) return;
        var a = input.ActiveWord ?? 0;
        EnsureNodes(Math.Min(words.Count - 1, a + 20), words);
        var node = Vector3d.From(_nodes[a]);
        var next = a + 1 < _nodes.Count ? Vector3d.From(_nodes[a + 1]) : node;
        var d = Vector3d.From(_dirs[a]);
        var side = Vector3d.Cross(d, new Vector3d(0, 1, 0)).Normalized();
        var scale = Math.Max(0.5, input.Theme.Scale);
        var desired = node - d * (220 / scale) + side * ((1000 + 160 * Math.Sin(input.Time * 0.19)) / scale) + new Vector3d(0, 170, 0);
        var turn = a > 0 ? _yaws[a] - _yaws[a - 1] : 0;
        var progress = input.ActiveWord is int aw ? CanvasKit.Smoothstep(input.Progress(words[aw])) : 0;
        var bankMax = _deep ? 0.5 : 0.25; var bankGain = _deep ? 0.9 : 0.35;
        Camera.Update(dt, desired, node, next, progress * 0.6, Math.Clamp(-turn * bankGain, -bankMax, bankMax), input.Bass, input.Velocity);
        MarkPrimed();
        Engine.Update(input, dt, Anchor, Camera);
    }

    public override void Build(SceneInput input, DrawList list, in CameraFrame frame)
    {
        var words = input.Lyrics.Words;
        if (words.Count == 0 || _nodes.Count == 0) return;
        var hl = Highlight(input); var sec = Secondary(input);
        var activeIndex = input.ActiveWord;
        var a = activeIndex ?? 0;
        int lo = Math.Max(0, a - 10), hi = Math.Min(words.Count - 1, a + 16);
        var right = frame.Right; var up = frame.Up;

        // Parallax starfield: seeded stars around every visible node, breathing with the bass.
        for (var i = lo; i <= hi; i++)
            for (var k = 0; k < 9; k++)
            {
                var seed = i * 53 + k;
                var off = new Vector3(Hash(seed * 3 + 1) - 0.5f, Hash(seed * 3 + 2) - 0.5f, Hash(seed * 3 + 3) - 0.5f) * 1500;
                var tw = 0.65f + 0.35f * MathF.Sin((float)input.Time * (0.8f + Hash(seed) * 2) + k);
                var r = (5 + 9 * Hash(seed + 9)) * (1 + 0.8f * (float)input.Bass);
                list.Sprite(DrawKind.Glow, _nodes[i] + off, r, new Vector4(1, 1, 1, (0.25f + 0.5f * Hash(seed + 5)) * tw), 2.4f, 0, DrawLayer.Glow, frame);
            }

        if (_deep)
        {
            // Three star shells at different depths: far shells ride with the camera (small parallax), near ones stay in the world.
            var shells = new (float Radius, float Follow, float Size)[] { (1800, 0.92f, 10), (3000, 0.65f, 15), (4600, 0.3f, 22) };
            for (var shell = 0; shell < shells.Length; shell++)
                for (var k = 0; k < 42; k++)
                {
                    var seed = shell * 977 + k * 31;
                    var dir = Vector3.Normalize(new Vector3(Hash(seed + 1) - 0.5f, Hash(seed + 2) - 0.5f, Hash(seed + 3) - 0.5f) + new Vector3(0, 0, 0.0001f));
                    var tw = 0.6f + 0.4f * MathF.Sin((float)input.Time * (0.6f + Hash(seed) * 1.8f) + k);
                    list.Sprite(DrawKind.Glow, frame.Position * shells[shell].Follow + dir * shells[shell].Radius, shells[shell].Size * (1 + 0.6f * (float)input.Bass),
                        new Vector4(1, 1, 1, (0.45f + 0.5f * Hash(seed + 5)) * tw), 2.4f, 0, DrawLayer.Glow, frame);
                }
        }

        // Dark scrim behind the active label.
        var activeCenter = _nodes[a] + up * 70;
        list.Sprite(DrawKind.Plume, activeCenter, 150, new Vector4(0.03f, 0.03f, 0.047f, 1), 0.78f, 2.2f, DrawLayer.Back, frame);

        // Filaments and struts.
        for (var i = Math.Max(1, lo); i <= Math.Max(1, hi) && i < _nodes.Count; i++)
        {
            var from = i - 1;
            double traced;
            if (activeIndex == null) traced = 0;
            else if (from < a) traced = 1;
            else if (from == a) traced = CanvasKit.Smoothstep(input.Progress(words[a]));
            else traced = 0;
            Vector3 p0 = _nodes[from], p1 = _nodes[i];
            var mid = (p0 + p1) * 0.5f;
            var px = PerPixel(frame.DepthOf(mid), frame);
            RibbonU(list, p0, p1, 2.0f * px, new Vector4(hl.X, hl.Y, hl.Z, 0.32f), 0.3f, frame);
            if (i >= 2) RibbonU(list, _nodes[i - 2], p1, 1.6f * px, new Vector4(sec.X, sec.Y, sec.Z, 0.5f), 0.3f, frame);
            if (i >= 3 && Vector3.Distance(_nodes[i - 3], p1) < 1100) RibbonU(list, _nodes[i - 3], p1, 1.3f * px, new Vector4(hl.X, hl.Y, hl.Z, 0.34f), 0.2f, frame);
            if (traced <= 0.001) continue;
            var live = from == a;
            var end = p0 + (p1 - p0) * (float)traced;
            var age = Math.Max(0, a - from);
            var alpha = live ? 0.95f : Math.Max(0.3f, 0.62f - age * 0.03f);
            var width = (live ? 2.6f : 1.5f) * px;
            var col = from % 2 == 0 ? hl : sec;
            list.Ribbon(p0, end, width * 3.0f, new Vector4(0, 0, 0, live ? 0.65f : 0.5f), 0, DrawLayer.Back, frame);
            RibbonU(list, p0, end, width * 1.6f, new Vector4(col.X, col.Y, col.Z, alpha), live ? 1.2f : 0.5f, frame);
            if (live) list.Sprite(DrawKind.Glow, end, 26, new Vector4(hl.X, hl.Y, hl.Z, 0.95f), 2, 0, DrawLayer.Glow, frame);
        }

        // Nodes, flares and labels.
        for (var i = lo; i <= hi; i++)
        {
            var p = _nodes[i]; var word = words[i];
            var isActive = i == a && activeIndex != null;
            var past = activeIndex != null && i < a;
            var age = (float)Math.Max(0, input.Pos - word.Start);
            var dof = frame.Dof(frame.DepthOf(p), 1400);
            var nodeAlpha = isActive ? 1f : past ? 0.35f : 0.2f;
            var breathe = _deep ? 1 + 0.55f * (float)input.Bass : 1f;
            list.Sprite(DrawKind.Glow, p, (isActive ? 64 : 40) * breathe, new Vector4(hl.X, hl.Y, hl.Z, nodeAlpha * 0.8f), 2, 0, DrawLayer.Glow, frame);
            list.Sprite(DrawKind.Glow, p, 10 + 4 * (float)input.Bass, new Vector4(1, 1, 1, Math.Min(1, nodeAlpha * 1.5f)), 1.6f, 0, DrawLayer.Glow, frame);
            if (isActive || (past && age < 1.4f))
            {
                var f = MathF.Exp(-age * 3);
                list.Sprite(DrawKind.Flare, p, 80 + 190 * f, new Vector4(hl.X, hl.Y, hl.Z, Math.Min(1, 0.4f + f)), 0, 0, DrawLayer.Glow, frame);
            }
            var mod = Engine.WordMod(i, input, isActive);
            var sideSign = Hash(i * 31 + 2) < 0.5f ? -1f : 1f;
            var height = isActive ? 84f : 52f;
            var labelCenter = p + up * (isActive ? 78 : sideSign * (height * 0.95f));
            var color = new Vector4(1, 1, 1, isActive ? 1 : past ? 0.42f : 0.18f);
            color.W *= dof.Fade;
            var blur = isActive || past ? 0 : 1.5f + Math.Min(2.5f, dof.Blur);
            list.Sprite(DrawKind.Plume, labelCenter, height * 0.8f, new Vector4(0.03f, 0.03f, 0.047f, 1), isActive ? 0.6f : 0.3f, 2.4f, DrawLayer.Back, frame);
            DrawWord(word.Text, labelCenter, height, right, up, color, mod, input, list, frame, blur: blur);
        }
        Engine.Draw(list, frame);
    }
}
