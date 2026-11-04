using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;

namespace EdgeGlow.Lyrics;

/// <summary>
/// Web: the active stanza hangs as a 3D tension mesh of spring-driven nodes. A newly sung word (or a bass transient)
/// pulls its node and neighbours toward the glass in z, and shockwave ripples run down the silk threads.
/// </summary>
public sealed class WebScene3D : Scene3D
{
    private sealed class Node { public Vector3 Pos, Vel, Rest; public float Alpha, HalfWidth; }
    private sealed record Ripple(int Origin, double Start, float Strength);

    private readonly Dictionary<int, Node> _nodes = new();
    private int _windowLine = -1;
    private List<(int, int)> _edges = new();
    private readonly Dictionary<int, List<int>> _adjacency = new();
    private readonly List<Ripple> _ripples = new();
    private int _lastActive = -1;
    private double _lastBass, _lastImpulse;
    private const float FontSize = 52;

    public WebScene3D(bool icons) : base(icons, 7) { }
    protected override void Reset2() { _nodes.Clear(); _edges.Clear(); _adjacency.Clear(); _ripples.Clear(); _windowLine = -1; _lastActive = -1; }

    private void Relayout(int line, TimedLyrics lyrics, LyricFont font)
    {
        _windowLine = line;
        var lineIds = new[] { line, line + 1 }.Where(l => l >= 0 && l < lyrics.Groups.Count).ToList();
        var ids = new List<int>(); var widths = new Dictionary<int, float>();
        var placed = new List<(int Id, float X, float Y)>();
        float rowY = 0; const float maxRow = 1250;
        for (var n = 0; n < lineIds.Count; n++)
        {
            if (n > 0) rowY += 80;
            var row = new List<(TimedWord W, float Cw)>(); float rowWidth = 0;
            void Flush()
            {
                if (row.Count == 0) return;
                var x = -rowWidth / 2;
                for (var k = 0; k < row.Count; k++)
                {
                    var (w, cw) = row[k];
                    var jitter = (Hash(w.Id * 5 + 1) - 0.5f) * 16;
                    var stagger = (k % 2 == 0 ? -1 : 1) * 30 * (Hash(w.Id * 9 + 2) + 0.4f);
                    placed.Add((w.Id, x + cw / 2 + jitter, rowY + stagger));
                    x += cw + 100;
                }
                rowY += 190; row.Clear(); rowWidth = 0;
            }
            foreach (var w in lyrics.Groups[lineIds[n]])
            {
                var cw = TextMetrics.Width(w.Text, font, FontSize) + 40;
                if (rowWidth + cw > maxRow && row.Count > 0) Flush();
                row.Add((w, cw)); rowWidth += cw + (row.Count > 1 ? 100 : 0);
                widths[w.Id] = cw; ids.Add(w.Id);
            }
            Flush();
        }
        var height = rowY - 100;
        var rests = new Dictionary<int, Vector3>();
        foreach (var (id, x, y) in placed) rests[id] = new Vector3(x, -(y - height / 2), (Hash(id * 7 + 3) - 0.5f) * 220);
        foreach (var id in ids)
        {
            var rest = rests[id];
            if (_nodes.TryGetValue(id, out var node)) { node.Rest = rest; node.HalfWidth = widths.GetValueOrDefault(id, 120) / 2; }
            else
            {
                var a = Hash(id * 3 + 7) * 2 * MathF.PI;
                _nodes[id] = new Node { Pos = rest + new Vector3(MathF.Cos(a) * 240, MathF.Sin(a) * 180, 220), Rest = rest, Alpha = 0, HalfWidth = widths.GetValueOrDefault(id, 120) / 2 };
            }
        }
        foreach (var id in _nodes.Keys.ToList())
            if (!ids.Contains(id)) { var n = _nodes[id]; n.Rest = new Vector3(n.Rest.X, n.Rest.Y + 120, n.Rest.Z + 200); }

        var set = new HashSet<(int, int)>();
        void Add(int a, int b) { if (a != b) set.Add((Math.Min(a, b), Math.Max(a, b))); }
        for (var k = 0; k < ids.Count; k++)
        {
            var id = ids[k];
            if (k > 0) Add(ids[k - 1], id);
            foreach (var other in ids.Where(o => o != id).OrderBy(o => Vector3.Distance(rests[o], rests[id])).Take(2)) Add(id, other);
        }
        _edges = set.ToList();
        _adjacency.Clear();
        foreach (var (a, b) in _edges)
        {
            if (!_adjacency.TryGetValue(a, out var la)) _adjacency[a] = la = new(); la.Add(b);
            if (!_adjacency.TryGetValue(b, out var lb)) _adjacency[b] = lb = new(); lb.Add(a);
        }
        foreach (var id in _nodes.Keys.ToList())
            if (!ids.Contains(id) && _nodes[id].Alpha < 0.01f) _nodes.Remove(id);
    }

    private SemanticKineticEngine.Anchor? Anchor(int index, SceneInput input)
    {
        var id = input.Lyrics.Words[index].Id;
        return _nodes.TryGetValue(id, out var n) ? new SemanticKineticEngine.Anchor(n.Pos, n.HalfWidth, FontSize) : null;
    }

    private void Pull(int id, float strength, double now)
    {
        if (!_nodes.TryGetValue(id, out var n)) return;
        n.Vel.Z -= 520 * strength;
        foreach (var other in _adjacency.GetValueOrDefault(id) ?? new())
        {
            if (!_nodes.TryGetValue(other, out var o)) continue;
            o.Vel.Z -= 260 * strength;
            o.Vel += Vector3.Normalize(n.Pos - o.Pos + new Vector3(0.001f, 0, 0)) * 90 * strength;
        }
        _ripples.Add(new Ripple(id, now, strength));
    }

    public override void Update(SceneInput input, double dt)
    {
        var lyrics = input.Lyrics;
        if (lyrics.IsEmpty) return;
        var line = input.Cursor.Index ?? input.Cursor.Next ?? 0;
        if (line != _windowLine) Relayout(line, lyrics, input.Theme.Font);
        var windowIds = new HashSet<int>(new[] { line, line + 1 }.Where(l => l >= 0 && l < lyrics.Groups.Count).SelectMany(l => lyrics.Groups[l].Select(w => w.Id)));
        int? active = input.ActiveWord is int aw ? lyrics.Words[aw].Id : null;

        if (active is int act && act != _lastActive && _nodes.ContainsKey(act)) { _lastActive = act; Pull(act, 1, input.Time); }
        var spike = input.Bass - _lastBass > 0.14 && input.Bass > 0.3;
        _lastBass = input.Bass;
        if (spike && input.Time - _lastImpulse > 0.2 && active is int a2 && _nodes.ContainsKey(a2))
        {
            _lastImpulse = input.Time;
            Pull(a2, 0.6f + (float)input.Bass * 0.6f, input.Time);
        }

        var h = (float)dt;
        foreach (var (id, n) in _nodes)
        {
            var inWindow = windowIds.Contains(id);
            n.Vel += ((n.Rest - n.Pos) * 95 - n.Vel * 9) * h;
            n.Pos += n.Vel * h;
            n.Alpha += ((inWindow ? 1 : 0) - n.Alpha) * (float)(1 - Math.Exp(-dt * (inWindow ? 5 : 3)));
        }
        _ripples.RemoveAll(r => input.Time - r.Start > 2.4);

        var target = new Vector3d(0, 0, 0);
        if (active is int a3 && _nodes.TryGetValue(a3, out var an)) target = Vector3d.From(an.Pos) * 0.4;
        var yaw = 0.45 * Math.Sin(input.Time * 0.23); var pitch = 0.1 * Math.Sin(input.Time * 0.19);
        var distance = 1050 / Math.Max(0.5, input.Theme.Scale);
        var position = target + new Vector3d(distance * Math.Sin(yaw), distance * 0.3 * Math.Sin(pitch) + 60, -distance * Math.Cos(yaw));
        Camera.Update(dt, position, target, target, 0, 0.03 * Math.Sin(input.Time * 0.3), input.Bass, input.Velocity);
        MarkPrimed();
        Engine.Update(input, dt, i => Anchor(i, input), Camera);
    }

    public override void Build(SceneInput input, DrawList list, in CameraFrame frame)
    {
        var lyrics = input.Lyrics;
        var hl = Highlight(input); var sec = Secondary(input);
        var right = frame.Right; var up = frame.Up;
        var activeIndex = input.ActiveWord;
        int? activeId = activeIndex is int ai ? lyrics.Words[ai].Id : null;
        var byId = lyrics.Words.ToDictionary(w => w.Id);

        if (activeId is int aid && _nodes.TryGetValue(aid, out var an))
            list.Sprite(DrawKind.Plume, an.Pos, 240, new Vector4(0.03f, 0.03f, 0.047f, 1), 0.78f, 2.1f, DrawLayer.Back, frame);

        foreach (var (a, b) in _edges)
        {
            if (!_nodes.TryGetValue(a, out var na) || !_nodes.TryGetValue(b, out var nb)) continue;
            var alpha = Math.Min(na.Alpha, nb.Alpha);
            if (alpha <= 0.02f) continue;
            var mid = (na.Pos + nb.Pos) * 0.5f;
            float wave = 0;
            foreach (var r in _ripples)
            {
                if (!_nodes.TryGetValue(r.Origin, out var origin)) continue;
                var t = (float)(input.Time - r.Start);
                var dist = Vector3.Distance(mid, origin.Pos);
                var d = (dist - 1300 * t) / 130;
                wave += MathF.Exp(-d * d) * MathF.Exp(-t * 1.5f) * r.Strength;
            }
            wave = Math.Min(wave, 1.6f);
            var px = PerPixel(frame.DepthOf(mid), frame);
            var involves = a == activeId || b == activeId;
            var col = (a + b) % 2 == 0 ? hl : sec;
            var width = (1.1f + 3.2f * wave + (involves ? 1f : 0)) * px;
            RibbonU(list, na.Pos, nb.Pos, width, new Vector4(col.X, col.Y, col.Z, alpha * (0.42f + 0.5f * Math.Min(1, wave) + (involves ? 0.2f : 0))), 0.5f + wave, frame);
        }

        foreach (var (id, n) in _nodes.OrderBy(k => k.Key))
        {
            if (!byId.TryGetValue(id, out var word) || n.Alpha <= 0.02f) continue;
            var isActive = id == activeId;
            var reached = input.Pos >= word.Start;
            var age = (float)Math.Max(0, input.Pos - word.Start);
            var dof = frame.Dof(frame.DepthOf(n.Pos), 1100);
            var pop = isActive ? 1.25f * (1 + 0.05f * MathF.Exp(-age * 6)) : 1f;
            var mod = Engine.WordMod(word.Id, input, isActive);
            var color = new Vector4(1, 1, 1, n.Alpha * (isActive ? 1 : reached ? 0.42f : 0.18f));
            color.W *= dof.Fade;
            list.Sprite(DrawKind.Glow, n.Pos, 16, new Vector4(hl.X, hl.Y, hl.Z, 0.4f * n.Alpha), 2, 0, DrawLayer.Glow, frame);
            list.Sprite(DrawKind.Plume, n.Pos + new Vector3(0, 0, 4), FontSize * 0.95f, new Vector4(0.03f, 0.03f, 0.047f, 1), (isActive ? 0.6f : 0.3f) * n.Alpha,
                Math.Max(1.3f, n.HalfWidth * 2 / FontSize * 0.7f), DrawLayer.Back, frame);
            if (isActive) list.Sprite(DrawKind.Glow, n.Pos, 120 + 40 * (float)input.Bass, new Vector4(hl.X, hl.Y, hl.Z, 0.5f), 2.2f, 0, DrawLayer.Glow, frame);
            DrawWord(word.Text, n.Pos, FontSize * pop, right, up, color, mod, input, list, frame, blur: isActive ? 0 : dof.Blur * 0.8f);
        }
        Engine.Draw(list, frame);
    }
}
