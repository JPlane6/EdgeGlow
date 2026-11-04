using System;
using System.Numerics;

namespace EdgeGlow.Lyrics;

/// <summary>A style: lays lyrics out in 3D world space, drives the cinematic camera and fills a <see cref="DrawList"/>.</summary>
public abstract class Scene3D
{
    public bool Icons { get; }
    public CinematicCamera3D Camera { get; }
    public SemanticKineticEngine Engine { get; set; } = new();
    public virtual bool UsesLens => false;
    private bool _primed;

    protected Scene3D(bool icons, int seed = 7) { Icons = icons; Camera = new CinematicCamera3D(seed); }

    public void Reset() { Camera.Reset(); _primed = false; Reset2(); }
    protected virtual void Reset2() { }
    protected void MarkPrimed() => _primed = true;
    protected bool Primed => _primed;

    public abstract void Update(SceneInput input, double dt);
    public abstract void Build(SceneInput input, DrawList list, in CameraFrame frame);

    protected static Vector4 Highlight(SceneInput i) => i.Theme.Highlight;
    protected static Vector4 Secondary(SceneInput i) => i.Theme.Secondary;
    public Vector4 HighlightOf(SceneInput i) => i.Theme.Highlight;

    protected static float PerPixel(float depth, in CameraFrame f) => depth / f.Focal;
    protected static float Hash(int i) => (float)CanvasKit.Hash(i);

    /// <summary>Adds a word. <paramref name="height"/> is the font size in world units. Returns the quad's world width.</summary>
    protected float DrawWord(string text, Vector3 center, float height, Vector3 right, Vector3 up, Vector4 color, WordMod mod,
                             SceneInput input, DrawList list, in CameraFrame frame, bool mono = false, float blur = 0, DrawLayer layer = DrawLayer.Body)
    {
        var run = TextMetrics.Run(text, input.Theme.Font, mono);
        var s = height / TextRun.RasterSize * (mono ? 1.25f : 1f);
        var w = run.Width * s; var h = run.Height * s;
        Vector3 r = right, u = up;
        if (mod.Roll != 0)
        {
            var c = MathF.Cos(mod.Roll); var sn = MathF.Sin(mod.Roll);
            r = right * c + up * sn; u = up * c - right * sn;
        }
        var halfW = w * 0.5f * mod.Scale.X * mod.Tracking; var halfH = h * 0.5f * mod.Scale.Y;
        center = center + right * (mod.Offset.X * height) + up * (mod.Offset.Y * height) + new Vector3(0, 0, mod.Offset.Z * height);

        if (mod.Glow.W > 0.01f)
            list.Sprite(DrawKind.Glow, center, Math.Max(halfW * 1.1f, halfH * 2.2f), new Vector4(mod.Glow.X, mod.Glow.Y, mod.Glow.Z, Math.Min(1, mod.Glow.W)), 2.2f, 0, DrawLayer.Glow, frame);

        // Legibility over any wallpaper: a crisp 1.5 px dark outline and a wide 14 px ambient shadow, both under the
        // word (and under its accent glow), so white letters separate from white backgrounds.
        if (color.W > 0.04f)
        {
            var k = Math.Min(1f, color.W * 2.5f);
            list.Text(text, mono, center, r * halfW, u * halfH, new Vector4(0, 0, 0, 0.75f * k), frame, shadowPx: 14, style: TextStyle.Shadow, layer: DrawLayer.Back);
            list.Text(text, mono, center, r * halfW, u * halfH, new Vector4(0, 0, 0, 0.5f * k), frame, shadowPx: 6, style: TextStyle.Shadow, layer: DrawLayer.Back);
            list.Text(text, mono, center, r * halfW, u * halfH, new Vector4(0, 0, 0, 0.92f * k), frame, style: TextStyle.Outline, layer: DrawLayer.Back);
        }
        list.Text(text, mono, center, r * halfW, u * halfH, color, frame, blur: blur, layer: layer);
        return w;
    }

    /// <summary>An emoji prop with a soft accent glow behind it.</summary>
    protected void Prop(string emoji, Vector3 center, float size, Vector3 right, Vector3 up, PropMod mod, Vector4 tint, SceneInput input, DrawList list, in CameraFrame frame)
    {
        if (mod.Alpha <= 0.01f) return;
        var sz = size * mod.Scale;
        var c = center + right * (mod.Offset.X * size) + up * (mod.Offset.Y * size);
        var halfH = sz * 0.42f; var halfW = halfH;
        list.Sprite(DrawKind.Plume, c, sz * 0.9f, new Vector4(0.03f, 0.03f, 0.047f, 1), 0.55f * mod.Alpha, 1, DrawLayer.Back, frame);
        list.Sprite(DrawKind.Glow, c, sz * 0.9f, new Vector4(tint.X, tint.Y, tint.Z, 0.35f * mod.Alpha), 2.2f, 0, DrawLayer.Glow, frame);
        list.Text(emoji, false, c, right * halfW, up * halfH, new Vector4(1, 1, 1, mod.Alpha), frame, kind: DrawKind.Icon);
    }

    /// <summary>Icon for a word: its semantic glyph, or the curated table as a fallback.</summary>
    protected string? VisualFor(int index, SceneInput input)
    {
        var tags = Engine.Tags;
        if (index >= 0 && index < tags.Count && WordVisualResolver.SymbolToEmoji(tags[index].Symbol) is { } e) return e;
        return WordVisualResolver.Visual(input.Lyrics.Words[index].Text);
    }

    /// <summary>A glowing filament over a dark 3 px under-stroke (65 % black), so lines hold up on a pure white screen.</summary>
    protected void RibbonU(DrawList list, Vector3 a, Vector3 b, float width, Vector4 color, float glow, DrawLayer layer, in CameraFrame cam)
    {
        if (layer != DrawLayer.Back)
        {
            var px = PerPixel(cam.DepthOf((a + b) * 0.5f), cam);
            list.Ribbon(a, b, width + 3 * px, new Vector4(0, 0, 0, 0.65f * Math.Min(1, color.W * 1.6f)), 0, DrawLayer.Back, cam);
        }
        list.Ribbon(a, b, width, color, glow, layer, cam);
    }
    protected void RibbonU(DrawList list, Vector3 a, Vector3 b, float width, Vector4 color, float glow, in CameraFrame cam) =>
        RibbonU(list, a, b, width, color, glow, DrawLayer.Glow, cam);
}
