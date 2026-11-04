using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;

namespace EdgeGlow.Lyrics;

/// <summary>
/// Codestyle Visual: lyrics as live, syntax-highlighted source code on a tilted holographic glass plane in 3D.
/// String literals are the lyric words (lit as they are sung), keywords come from each line's semantic archetype
/// (`await drive(speed: .fast...)`, `try crash(...)`), the caret follows the sung word and props fire beside the active string.
/// </summary>
public sealed class CodeScene3D : Scene3D
{
    private enum Kind { Keyword, Ident, Punct, Quote, Word, Comment }
    private sealed record Seg(string Text, Kind Kind, int? WordId = null);
    private sealed record Row(int Indent, List<Seg> Segs, int? Line);

    private readonly List<Row> _rows = new();
    private readonly Dictionary<int, int> _rowOfLine = new();
    private Spring1 _scroll, _panelScroll;
    private bool _scrollPrimed;
    private const float H = 40;
    private float _charWidth = 24;

    public CodeScene3D(bool icons) : base(icons, 7) { }
    protected override void Reset2() { _rows.Clear(); _rowOfLine.Clear(); _scroll = default; _panelScroll = default; _scrollPrimed = false; }

    private void BuildRows(TimedLyrics lyrics)
    {
        _rows.Clear(); _rowOfLine.Clear();
        var stanza = 0;
        for (var li = 0; li < lyrics.Groups.Count; li++)
        {
            var group = lyrics.Groups[li];
            var start = group.Count > 0 ? group[0].Start : 0;
            var prevEnd = li > 0 && lyrics.Groups[li - 1].Count > 0 ? lyrics.Groups[li - 1][^1].End : -10;
            if (li == 0 || start - prevEnd > 2.4)
            {
                if (li > 0) _rows.Add(new Row(0, new() { new Seg("}", Kind.Punct) }, null));
                stanza++;
                var name = stanza == 2 ? "chorus" : $"verse{stanza}";
                _rows.Add(new Row(0, new() { new Seg($"// {name}", Kind.Comment) }, null));
                _rows.Add(new Row(0, new() { new Seg("func ", Kind.Keyword), new Seg(name, Kind.Ident), new Seg("() async {", Kind.Punct) }, null));
            }
            var archetype = group.Select(w => Engine.Tags.Count > w.Id ? Engine.Tags[w.Id].Archetype : Archetype.None).FirstOrDefault(x => x != Archetype.None);
            List<Seg> lead; var tail = new List<Seg> { new(")", Kind.Punct) };
            switch (archetype)
            {
                case Archetype.Velocity: lead = new() { new("await ", Kind.Keyword), new("drive", Kind.Ident), new("(speed: ", Kind.Punct), new(".fast", Kind.Keyword), new(", ", Kind.Punct) }; break;
                case Archetype.Impact: lead = new() { new("try ", Kind.Keyword), new("crash", Kind.Ident), new("(.hard, ", Kind.Punct) }; break;
                case Archetype.Fire: lead = new() { new("await ", Kind.Keyword), new("ignite", Kind.Ident), new("(heat: ", Kind.Punct), new(".max", Kind.Keyword), new(", ", Kind.Punct) }; break;
                case Archetype.Heart or Archetype.Tears: lead = new() { new("await ", Kind.Keyword), new("pulse", Kind.Ident), new("(bpm: ", Kind.Punct), new("72", Kind.Keyword), new(", ", Kind.Punct) }; break;
                case Archetype.Cosmic: lead = new() { new("await ", Kind.Keyword), new("orbit", Kind.Ident), new("(altitude: ", Kind.Punct), new(".high", Kind.Keyword), new(", ", Kind.Punct) }; break;
                case Archetype.Vibe: lead = new() { new("await ", Kind.Keyword), new("amplify", Kind.Ident), new("(gain: ", Kind.Punct), new("11", Kind.Keyword), new(", ", Kind.Punct) }; break;
                default:
                {
                    var t = (int)(CanvasKit.Hash(li * 5 + 3) * 3);
                    if (t == 0) { lead = new() { new("let ", Kind.Keyword), new($"line{li + 1}", Kind.Ident), new(" = ", Kind.Punct) }; tail = new(); }
                    else if (t == 1) lead = new() { new("print", Kind.Ident), new("(", Kind.Punct) };
                    else { lead = new() { new("return ", Kind.Keyword) }; tail = new(); }
                    break;
                }
            }
            var segs = new List<Seg>(lead) { new("\"", Kind.Quote) };
            for (var k = 0; k < group.Count; k++)
            {
                segs.Add(new Seg(group[k].Text, Kind.Word, group[k].Id));
                if (k < group.Count - 1) segs.Add(new Seg(" ", Kind.Punct));
            }
            segs.Add(new Seg("\"", Kind.Quote)); segs.AddRange(tail);
            _rowOfLine[li] = _rows.Count;
            _rows.Add(new Row(1, segs, li));
        }
        _rows.Add(new Row(0, new() { new Seg("}", Kind.Punct) }, null));
    }

    private readonly record struct Basis(Vector3 Right, Vector3 Up, Vector3 Normal);

    private static Vector3 Rot(Vector3 v, float yaw, float pitch)
    {
        // pitch about X, then yaw about Y.
        var cp = MathF.Cos(pitch); var sp = MathF.Sin(pitch);
        var v1 = new Vector3(v.X, v.Y * cp - v.Z * sp, v.Y * sp + v.Z * cp);
        var cy = MathF.Cos(yaw); var sy = MathF.Sin(yaw);
        return new Vector3(v1.X * cy + v1.Z * sy, v1.Y, -v1.X * sy + v1.Z * cy);
    }

    private static Basis BasisAt(double t)
    {
        var yaw = (float)(0.42 + 0.12 * Math.Sin(t * 0.27)); var pitch = (float)(-0.14 + 0.05 * Math.Sin(t * 0.21));
        return new Basis(Rot(Vector3.UnitX, yaw, pitch), Rot(Vector3.UnitY, yaw, pitch), Rot(Vector3.UnitZ, yaw, pitch));
    }

    private static Vector3 World(float u, float v, Basis b) => b.Right * u + b.Up * v;

    private SemanticKineticEngine.Anchor? Anchor(int index, SceneInput input)
    {
        var line = input.Lyrics.Words[index].Line;
        if (!_rowOfLine.TryGetValue(line, out var r)) return null;
        return new SemanticKineticEngine.Anchor(World(0, -r * H * 1.7f, BasisAt(input.Time)), 300, H);
    }

    public override void Update(SceneInput input, double dt)
    {
        if (_rows.Count == 0) BuildRows(input.Lyrics);
        var line = input.Cursor.Index ?? input.Cursor.Next ?? 0;
        var target = _rowOfLine.TryGetValue(line, out var r) ? r : 0;
        if (!_scrollPrimed) { _scroll = new Spring1(target); _panelScroll = new Spring1(target); _scrollPrimed = true; }
        _scroll.Step(target, dt, 170, 20); _panelScroll.Step(target, dt, 120, 18);

        var b = BasisAt(input.Time);
        var lh = H * 1.7f;
        var center = World(0, -(float)_scroll.Value * lh, b);
        var distance = 1250 / Math.Max(0.5, input.Theme.Scale);
        var n = Vector3d.From(b.Normal); var t3 = Vector3d.From(center);
        Camera.Update(dt, t3 - n * distance, t3, t3, 0, 0.02 * Math.Sin(input.Time * 0.3), input.Bass, input.Velocity);
        MarkPrimed();
        Engine.Update(input, dt, i => Anchor(i, input), Camera);
    }

    public override void Build(SceneInput input, DrawList list, in CameraFrame frame)
    {
        if (_rows.Count == 0) return;
        var lyrics = input.Lyrics;
        var hl = Highlight(input); var sec = Secondary(input);
        var b = BasisAt(input.Time);
        var lh = H * 1.7f;
        var activeLine = input.Cursor.Index ?? input.Cursor.Next ?? 0;
        var activeRow = _rowOfLine.TryGetValue(activeLine, out var ar) ? ar : 0;
        _charWidth = TextMetrics.Run("M", input.Theme.Font, true).Width * H / TextRun.RasterSize * 1.25f;
        var cw = _charWidth;

        var visible = Enumerable.Range(0, _rows.Count).Where(i => Math.Abs(i - activeRow) <= 6);
        var maxChars = Math.Max(30, visible.Select(i => _rows[i].Indent * 4 + _rows[i].Segs.Sum(s => s.Text.Length)).DefaultIfEmpty(30).Max());
        var panelW = (maxChars + 10) * cw;
        var panelH = lh * 13;
        var gutter = cw * 4;
        var left = -panelW / 2 + gutter + cw * 2;
        var panelCenterV = -(float)_panelScroll.Value * lh;

        // Glass panel with a dark backing (legible over any window) and its soft glow.
        list.Panel(World(0, panelCenterV, b), b.Right * (panelW / 2), b.Up * (panelH / 2), new Vector4(hl.X, hl.Y, hl.Z, 0.92f), 0.03f, 1.0f, panelW / panelH, DrawLayer.Back, frame);
        list.Sprite(DrawKind.Glow, World(0, panelCenterV, b) + b.Normal * 20, panelW * 0.5f, new Vector4(hl.X, hl.Y, hl.Z, 0.05f + 0.1f * (float)input.Bass), 1.6f, 0, DrawLayer.Glow, frame);

        DrawWord("lyrics.cs", World(0, panelCenterV + panelH / 2 - lh * 0.1f, b), H * 0.7f, b.Right, b.Up, new Vector4(1, 1, 1, 0.5f), WordMod.Identity, input, list, frame, mono: true);
        var dots = new[] { new Vector4(1, 0.35f, 0.35f, 0.8f), new Vector4(1, 0.8f, 0.3f, 0.8f), new Vector4(0.35f, 0.9f, 0.45f, 0.8f) };
        for (var k = 0; k < 3; k++)
            list.Sprite(DrawKind.Glow, World(-panelW / 2 + cw * (1.6f + k * 1.5f), panelCenterV + panelH / 2 - lh * 0.1f, b), 9, dots[k], 1.2f, 0, DrawLayer.Glow, frame);

        Vector3? caret = null;
        var rowIcons = new List<(string Emoji, int Id, Vector3 At)>();
        int lo = Math.Max(0, activeRow - 6), hi = Math.Min(_rows.Count - 1, activeRow + 6);
        for (var r = lo; r <= hi; r++)
        {
            var row = _rows[r];
            var v = -r * lh;
            var d = Math.Abs(r - _panelScroll.Value);
            var dim = (float)(1 / (1 + 0.38 * d));
            var isActiveRow = r == activeRow;
            var dof = frame.Dof(frame.DepthOf(World(0, v, b)), 1200);

            if (isActiveRow)
                list.Panel(World(0, v, b) + b.Normal * -2, b.Right * (panelW / 2), b.Up * (lh / 2), new Vector4(1, 1, 1, 0.1f), 0.02f, 0, panelW / lh, DrawLayer.Back, frame);
            DrawWord($"{r + 1}", World(-panelW / 2 + gutter - cw * 0.3f, v, b), H * 0.82f, b.Right, b.Up, new Vector4(1, 1, 1, (isActiveRow ? 0.75f : 0.28f) * dim), WordMod.Identity, input, list, frame, mono: true, blur: dof.Blur * 0.5f);

            var col = row.Indent * 4;
            float? lastReachedU = null;
            foreach (var seg in row.Segs)
            {
                var width = seg.Text.Length * cw;
                var uCenter = left + (col + seg.Text.Length / 2f) * cw;
                Vector4 color; var mod = WordMod.Identity; var alpha = dim * dof.Fade;
                switch (seg.Kind)
                {
                    case Kind.Keyword: color = new Vector4(Math.Min(1, sec.X + 0.25f), Math.Min(1, sec.Y + 0.25f), Math.Min(1, sec.Z + 0.25f), 1); break;
                    case Kind.Ident: color = new Vector4(1, 1, 1, 0.92f); break;
                    case Kind.Punct: color = new Vector4(1, 1, 1, 0.55f); break;
                    case Kind.Quote: color = new Vector4(hl.X, hl.Y, hl.Z, 0.75f); break;
                    case Kind.Comment: color = new Vector4(1, 1, 1, 0.38f); break;
                    default:
                        color = hl;
                        if (seg.WordId is int id)
                        {
                            var w = lyrics.Words[id];
                            var reached = input.Pos >= w.Start;
                            var active = id == input.ActiveWord;
                            mod = Engine.WordMod(id, input, active);
                            if (active)
                            {
                                color = new Vector4(1, 1, 1, 1);
                                list.Sprite(DrawKind.Glow, World(uCenter, v, b) + b.Normal * -4, width * 0.8f + 70, new Vector4(hl.X, hl.Y, hl.Z, 0.6f), 2.2f, 0, DrawLayer.Glow, frame);
                            }
                            else if (reached) color = new Vector4(Math.Min(1, hl.X + 0.25f), Math.Min(1, hl.Y + 0.25f), Math.Min(1, hl.Z + 0.25f), 1);
                            else alpha *= isActiveRow ? 0.5f : 0.7f;
                            if (reached) lastReachedU = uCenter + width / 2;
                            if (active && VisualFor(id, input) is { } vis) rowIcons.Add((vis, id, World(uCenter, v, b)));
                        }
                        break;
                }
                color.W *= alpha;
                if (seg.Text != " ")
                    DrawWord(seg.Text, World(uCenter, v, b), H, b.Right, b.Up, color, mod, input, list, frame, mono: true, blur: dof.Blur * 0.6f);
                col += seg.Text.Length;
            }

            if (isActiveRow)
            {
                var u = lastReachedU ?? left + (row.Indent * 4 + 1) * cw;
                caret = World(u + cw * 0.15f, v, b);
                var endU = Math.Min(left + col * cw + cw * 2.2f, panelW / 2 - H * 3);
                if (Icons)
                    for (var k = 0; k < Math.Min(4, rowIcons.Count); k++)
                    {
                        var entry = rowIcons[Math.Max(0, rowIcons.Count - 4) + k];
                        Prop(entry.Emoji, World(endU + k * H * 1.5f, v + 4, b) + b.Normal * -10, H * 1.5f, b.Right, b.Up, Engine.PropMod(entry.Id, input), Engine.Tint(entry.Id, hl), input, list, frame);
                    }
            }
        }

        if (caret is { } cp && Math.Sin(input.Time * 7) > -0.35)
        {
            list.Sprite(DrawKind.Glow, cp + b.Normal * -6, 30, new Vector4(hl.X, hl.Y, hl.Z, 0.9f), 2, 0, DrawLayer.Glow, frame);
            list.Panel(cp + b.Normal * -8, b.Right * 3, b.Up * (lh * 0.42f), new Vector4(1, 1, 1, 1), 0, 0, 6 / (lh * 0.84f), DrawLayer.Glow, frame);
        }
        Engine.Draw(list, frame);
    }
}
