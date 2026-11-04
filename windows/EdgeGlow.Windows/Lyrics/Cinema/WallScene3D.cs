using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;

namespace EdgeGlow.Lyrics;

/// <summary>A typeset wall of lyric lines in flat "wall units" (wrapped, centered rows). Shared by every wall style.</summary>
public sealed class WallLayout
{
    public sealed record Item(int WordIndex, float X, float Y, float Width);

    public const float FontSize = 54;
    private readonly float _maxWidth;
    private readonly LyricFont _font;
    public List<List<Item>> Items { get; } = new();
    public List<float> LineTop { get; } = new();
    public List<float> LineHeight { get; } = new();

    public WallLayout(float maxWidth, LyricFont font) { _maxWidth = maxWidth; _font = font; }
    public int Count => Items.Count;

    public void Ensure(int line, TimedLyrics lyrics)
    {
        while (Items.Count <= Math.Min(line, lyrics.Groups.Count - 1))
        {
            var li = Items.Count;
            var words = lyrics.Groups[li];
            var rowHeight = FontSize * 1.3f; var gap = FontSize * 0.62f;
            var rows = new List<List<(TimedWord W, float Cw)>> { new() };
            float rowWidth = 0;
            foreach (var w in words)
            {
                var cw = TextMetrics.Width(w.Text, _font, FontSize);
                if (rowWidth + cw > _maxWidth && rows[^1].Count > 0) { rows.Add(new()); rowWidth = 0; }
                rows[^1].Add((w, cw));
                rowWidth += cw + gap;
            }
            var top = (LineTop.Count > 0 ? LineTop[^1] : 0) + (LineHeight.Count > 0 ? LineHeight[^1] : 0) + (li == 0 ? 0 : FontSize * 0.75f);
            var lineItems = new List<Item>();
            for (var r = 0; r < rows.Count; r++)
            {
                var row = rows[r];
                var total = row.Sum(x => x.Cw) + gap * Math.Max(0, row.Count - 1);
                var x = -total / 2;
                foreach (var (w, cw) in row)
                {
                    lineItems.Add(new Item(w.Id, x + cw / 2, top + rowHeight * (r + 0.5f), cw));
                    x += cw + gap;
                }
            }
            Items.Add(lineItems); LineTop.Add(top); LineHeight.Add(rowHeight * rows.Count);
        }
    }

    public Item? ItemFor(int wordIndex, int line) =>
        line >= 0 && line < Items.Count ? Items[line].FirstOrDefault(i => i.WordIndex == wordIndex) : null;
}

/// <summary>
/// Ship, Visual, Fisheye, Fisheye Visual and HyperShip 3D: a 3D architectural word wall in real perspective.
/// Each sung word stamps onto the wall with spring physics while the camera dollies, pans and orbits across it.
/// </summary>
public sealed class WallScene3D : Scene3D
{
    private readonly bool _lens, _stage;
    private WallLayout? _layout;
    public override bool UsesLens => _lens;

    public WallScene3D(bool icons, bool lens, bool stage = false) : base(icons, lens ? 11 : stage ? 23 : 5) { _lens = lens; _stage = stage; }
    protected override void Reset2() => _layout = null;

    private static int ActiveLine(SceneInput i) => i.Cursor.Index ?? i.Cursor.Next ?? 0;
    private static Vector3 World(WallLayout.Item item, float z = 0) => new(item.X, -item.Y, z);

    private SemanticKineticEngine.Anchor? Anchor(int index, SceneInput input)
    {
        if (_layout == null) return null;
        var item = _layout.ItemFor(index, input.Lyrics.Words[index].Line);
        return item == null ? null : new SemanticKineticEngine.Anchor(World(item), item.Width / 2, WallLayout.FontSize);
    }

    public override void Update(SceneInput input, double dt)
    {
        var lyrics = input.Lyrics;
        if (lyrics.IsEmpty) return;
        _layout ??= new WallLayout(_lens ? 980 : 900, input.Theme.Font);
        var line = ActiveLine(input);
        _layout.Ensure(line + 4, lyrics);

        var target = new Vector3d(0, 0, 0); var next = target;
        if (line < _layout.LineTop.Count)
        {
            target = new Vector3d(0, -(_layout.LineTop[line] + _layout.LineHeight[line] / 2), 0); next = target;
        }
        if (input.ActiveWord is int a && _layout.ItemFor(a, lyrics.Words[a].Line) is { } item)
        {
            target = new Vector3d(item.X * 0.85, -item.Y, 0); next = target;
            if (a + 1 < lyrics.Words.Count && _layout.ItemFor(a + 1, lyrics.Words[a + 1].Line) is { } n) next = new Vector3d(n.X * 0.85, -n.Y, 0);
        }
        var t = input.Time;
        var yaw = _stage ? 0.42 + 0.05 * Math.Sin(t * 0.3) : 0.2 + 0.36 * Math.Sin(t * 0.21) + 0.03 * input.Vocal;
        var pitch = 0.10 * Math.Sin(t * 0.17 + 1);
        var punch = _stage ? 90 * input.Bass : 0;
        var distance = ((_lens ? 640 : 540) - punch) / Math.Max(0.5, input.Theme.Scale);
        var lift = _stage ? distance * 0.14 + 12 * Math.Sin(t * 0.5) : distance * 0.28 * Math.Sin(pitch) + 30;
        var position = target + new Vector3d(distance * Math.Sin(yaw), lift, -distance * Math.Cos(yaw));
        var anticipation = input.ActiveWord is int aw ? CanvasKit.Smoothstep(input.Progress(lyrics.Words[aw])) * 0.7 : 0;
        Camera.Update(dt, position, target, next, anticipation, 0.03 * Math.Sin(t * 0.4), input.Bass, input.Velocity);
        MarkPrimed();
        Engine.Update(input, dt, i => Anchor(i, input), Camera);
    }

    public override void Build(SceneInput input, DrawList list, in CameraFrame frame)
    {
        if (_layout == null) return;
        var lyrics = input.Lyrics;
        var hl = Highlight(input);
        var line = ActiveLine(input);
        var U = WallLayout.FontSize;
        var right = Vector3.UnitX; var up = Vector3.UnitY;
        var activeIndex = input.ActiveWord;
        int lo = Math.Max(0, line - 3), hi = Math.Min(_layout.Count - 1, line + 3);
        if (lo > hi) return;

        // Dynamic scrim behind the focal cluster (the active line): rgba(8,8,12) at 0.78 in the core, feathering out.
        if (line < _layout.Items.Count && _layout.Items[line].Count > 0)
        {
            var items = _layout.Items[line];
            var minX = items.Min(i => i.X - i.Width / 2); var maxX = items.Max(i => i.X + i.Width / 2);
            var y = items.Average(i => i.Y);
            var c = new Vector3((minX + maxX) / 2, -y, 40);
            var widthWorld = maxX - minX;
            var pr = Math.Max(160, U * 3.0f);
            list.Sprite(DrawKind.Plume, c, pr, new Vector4(0.03f, 0.03f, 0.047f, 1), 0.78f, Math.Max(2.6f, widthWorld * 0.8f / pr), DrawLayer.Back, frame);
        }

        for (var li = lo; li <= hi; li++)
        {
            var dl = li - line;
            var lineAlpha = dl == 0 ? 1f : dl < 0 ? 0.55f / -dl + 0.1f : 0.6f / dl + 0.08f;
            foreach (var item in _layout.Items[li])
            {
                var index = item.WordIndex;
                var word = lyrics.Words[index];
                var reached = input.Pos >= word.Start;
                var isActive = activeIndex == index;
                var age = (float)Math.Max(0, input.Pos - word.Start);

                var z = Math.Abs(dl) * 70f + MathF.Sin(index * 0.9f + (float)input.Time * 1.3f) * 22;
                if (reached && age < 1.4f) z -= (float)(1 - CanvasKit.Spring(age)) * 50;
                if (dl == 0) z -= (float)input.Bass * 30;
                if (isActive) z -= _stage ? 30 : 10;

                var mod = Engine.WordMod(index, input, isActive);
                var center = World(item, z);
                var depth = frame.DepthOf(center);
                var dof = frame.Dof(depth, 1100);

                Vector4 color;
                if (isActive) color = new Vector4(1, 1, 1, 1);
                else if (dl == 0) color = new Vector4(1, 1, 1, reached ? 0.42f : 0.18f);
                else color = new Vector4(1, 1, 1, Math.Min(0.18f, lineAlpha * 0.2f));
                if (_lens && !isActive) color.W = Math.Min(0.55f, color.W * 2.2f);   // glass dome backing is dark
                color.W *= dof.Fade;
                var blur = isActive || (dl == 0 && reached) ? 0 : 1.5f + Math.Min(2.5f, dof.Blur);

                if (isActive)
                    list.Sprite(DrawKind.Glow, center, Math.Max(item.Width * 0.9f, 110), new Vector4(hl.X, hl.Y, hl.Z, 0.30f + 0.12f * (float)input.Bass), 2.2f, 0, DrawLayer.Glow, frame);
                DrawWord(word.Text, center, U, right, up, color, mod, input, list, frame, blur: blur);

                if (Icons && isActive && VisualFor(index, input) is { } v)
                {
                    var pm = Engine.PropMod(index, input);
                    var anchorPoint = center + new Vector3(item.Width / 2 + U * 0.3f, U * 0.95f, -8);
                    Prop(v, anchorPoint, U * 1.15f, right, up, pm, Engine.Tint(index, hl), input, list, frame);
                }
            }
        }
        Engine.Draw(list, frame);
    }
}
