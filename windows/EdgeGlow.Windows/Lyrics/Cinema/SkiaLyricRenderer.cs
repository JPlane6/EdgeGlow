using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;
using SkiaSharp;

namespace EdgeGlow.Lyrics;

public readonly record struct LensParams(float CenterX, float CenterY, float RadiusX, float RadiusY, float K = 0.9f, float Magnification = 1.35f, float Chroma = 0.07f);

/// <summary>
/// Rasterizes a <see cref="DrawList"/> with SkiaSharp. Words are real vector glyphs drawn under a perspective
/// homography (so they stay razor sharp at any depth and angle); the Fisheye lens is an SkSL barrel-distortion
/// shader with chromatic aberration over a supersampled copy of the scene.
/// </summary>
public sealed class SkiaLyricRenderer : IDisposable
{
    private const float NearPlane = 40;
    private const float LensSupersample = 1.0f;     // was 1.3: the supersampled lens pass cost ~70 % more pixels
    private static readonly DrawLayer[] Layers = { DrawLayer.Back, DrawLayer.Body, DrawLayer.Glow, DrawLayer.Top };
    private SKSurface? _lensSurface;
    private int _lensW, _lensH;
    private LyricFont _font = LyricFont.SfPro;

    public void Dispose()
    {
        _lensSurface?.Dispose();
        foreach (var image in _emojiImages.Values) image.Dispose();
        foreach (var entry in _wordCache.Values) entry.Image?.Dispose();
        foreach (var image in _profiles.Values) image.Dispose();
    }

    // ---------------------------------------------------------------- Entry

    public void Render(SKCanvas canvas, DrawList list, in CameraFrame cam, float w, float h, double focusY, LyricFont font,
                       LensParams? lens, Vector3 highlight, float alpha = 1)
    {
        _font = font;
        _frameNumber++;
        TrimWordCache();
        var cy = h * (0.5f + (float)(focusY - 0.5) * 0.5f);
        if (lens is not { } lp)
        {
            DrawItems(canvas, list, cam, w, h, cy, 1f, alpha);
            return;
        }

        DrawDomeBacking(canvas, lp, highlight, alpha);
        var ss = LensSupersample;
        var sw = (int)Math.Ceiling(w * ss); var sh = (int)Math.Ceiling(h * ss);
        if (_lensSurface == null || _lensW != sw || _lensH != sh)
        {
            _lensSurface?.Dispose();
            _lensSurface = SKSurface.Create(new SKImageInfo(sw, sh, SKColorType.Bgra8888, SKAlphaType.Premul));
            _lensW = sw; _lensH = sh;
        }
        var off = _lensSurface!.Canvas;
        off.Clear(SKColors.Transparent);
        DrawItems(off, list, cam, w, h, cy, ss, 1f);
        off.Flush();
        using var image = _lensSurface.Snapshot();
        DrawLensed(canvas, image, lp, ss, alpha);
        DrawRim(canvas, lp, highlight, alpha);
    }

    // ---------------------------------------------------------------- Items

    private void DrawItems(SKCanvas canvas, DrawList list, in CameraFrame cam, float w, float h, float cy, float ss, float alpha)
    {
        var center = new Vector2(w * 0.5f, cy);
        foreach (var layer in Layers)
        {
            IEnumerable<DrawItem> items = list.Items.Where(i => i.Layer == layer);
            if (layer == DrawLayer.Body || layer == DrawLayer.Back) items = items.OrderByDescending(i => i.Depth);
            foreach (var item in items)
            {
                var color = item.Color; color.W *= alpha;
                if (color.W <= 0.002f) continue;
                switch (item.Kind)
                {
                    case DrawKind.Text: case DrawKind.Icon: DrawText(canvas, item, color, cam, center, ss); break;
                    case DrawKind.Ribbon: DrawRibbon(canvas, item, color, cam, center, ss); break;
                    case DrawKind.Panel: DrawPanel(canvas, item, color, cam, center, ss); break;
                    default: DrawSprite(canvas, item, color, cam, center, ss); break;
                }
            }
        }
    }

    private static bool Project(Vector3 p, in CameraFrame cam, Vector2 center, float ss, out SKPoint s, out float z)
    {
        var v = p - cam.Position;
        var x = Vector3.Dot(v, cam.Right); var y = Vector3.Dot(v, cam.Up); z = Vector3.Dot(v, cam.Forward);
        if (z <= NearPlane) { s = default; return false; }
        var k = cam.Focal / z;
        s = new SKPoint((center.X + x * k) * ss, (center.Y - y * k) * ss);
        return true;
    }

    private static SKColor Rgba(Vector4 c, float aMul = 1) =>
        new((byte)Math.Clamp(c.X * 255, 0, 255), (byte)Math.Clamp(c.Y * 255, 0, 255), (byte)Math.Clamp(c.Z * 255, 0, 255), (byte)Math.Clamp(c.W * aMul * 255, 0, 255));

    /// <summary>Square-to-quad homography (Heckbert): unit square corners (0,0),(1,0),(1,1),(0,1) to p0..p3.</summary>
    private static SKMatrix? Homography(SKPoint p0, SKPoint p1, SKPoint p2, SKPoint p3)
    {
        double x0 = p0.X, y0 = p0.Y, x1 = p1.X, y1 = p1.Y, x2 = p2.X, y2 = p2.Y, x3 = p3.X, y3 = p3.Y;
        double dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
        double dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
        double a, b, c = x0, d, e, f = y0, g, hh;
        if (Math.Abs(dx3) < 1e-9 && Math.Abs(dy3) < 1e-9)
        {
            a = x1 - x0; b = x2 - x1; d = y1 - y0; e = y2 - y1; g = 0; hh = 0;
            b = x3 - x0; e = y3 - y0;
        }
        else
        {
            var den = dx1 * dy2 - dy1 * dx2;
            if (Math.Abs(den) < 1e-9) return null;
            g = (dx3 * dy2 - dy3 * dx2) / den;
            hh = (dx1 * dy3 - dy1 * dx3) / den;
            a = x1 - x0 + g * x1; b = x3 - x0 + hh * x3;
            d = y1 - y0 + g * y1; e = y3 - y0 + hh * y3;
        }
        return new SKMatrix { ScaleX = (float)a, SkewX = (float)b, TransX = (float)c, SkewY = (float)d, ScaleY = (float)e, TransY = (float)f, Persp0 = (float)g, Persp1 = (float)hh, Persp2 = 1 };
    }

    private static float Dist(SKPoint a, SKPoint b) => MathF.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    private bool Quad(in DrawItem item, in CameraFrame cam, Vector2 center, float ss, out SKPoint[] pts)
    {
        pts = new SKPoint[4];
        var corners = new[] { item.C0, item.C1, item.C2, item.C3 };
        for (var i = 0; i < 4; i++)
            if (!Project(corners[i], cam, center, ss, out pts[i], out _)) return false;
        return true;
    }

    private readonly Dictionary<string, SKImage> _emojiImages = new();

    /// <summary>Color emoji are bitmap glyphs and do not survive a perspective matrix, so each is rasterized once to an image.</summary>
    private SKImage? EmojiImage(string emoji)
    {
        if (_emojiImages.TryGetValue(emoji, out var hit)) return hit;
        var run = TextMetrics.Run(emoji, _font, false, true);
        if (run.Blob is null) return null;
        const int side = 256;
        using var surface = SKSurface.Create(new SKImageInfo(side, side, SKColorType.Bgra8888, SKAlphaType.Premul));
        surface.Canvas.Clear(SKColors.Transparent);
        var s = side * 0.92f / run.Height;
        surface.Canvas.Translate((side - run.Width * s) / 2, (side - run.Height * s) / 2);
        surface.Canvas.Scale(s);
        using var paint = new SKPaint { IsAntialias = true, Color = SKColors.White };
        surface.Canvas.DrawText(run.Blob, 0, -run.Ascent, paint);
        return _emojiImages[emoji] = surface.Snapshot();
    }

    private void DrawIcon(SKCanvas canvas, in DrawItem item, Vector4 color, in CameraFrame cam, Vector2 center, float ss)
    {
        if (item.Text is null || !Quad(item, cam, center, ss, out var p) || EmojiImage(item.Text) is not { } image) return;
        var m = Homography(p[0], p[1], p[2], p[3]);
        if (m is null) return;
        canvas.Save();
        canvas.SetMatrix(SKMatrix.Concat(m.Value, SKMatrix.CreateScale(1f / image.Width, 1f / image.Height)));
        using var paint = new SKPaint { IsAntialias = true, FilterQuality = SKFilterQuality.High, Color = SKColors.White.WithAlpha((byte)Math.Clamp(color.W * 255, 0, 255)) };
        canvas.DrawImage(image, 0, 0, paint);
        canvas.Restore();
    }

    private void DrawText(SKCanvas canvas, in DrawItem item, Vector4 color, in CameraFrame cam, Vector2 center, float ss)
    {
        if (item.Kind == DrawKind.Icon) { DrawIcon(canvas, item, color, cam, center, ss); return; }
        if (item.Text is null || !Quad(item, cam, center, ss, out var p)) return;
        const bool emoji = false;
        var run = TextMetrics.Run(item.Text, _font, item.Mono, emoji);
        if (run.Blob is null) return;
        var m = Homography(p[0], p[1], p[2], p[3]);
        if (m is null) return;
        // Text space (x in 0..Width, y in 0..Height) to the unit square, then the homography.
        // Emoji are drawn into a square box (their advance is narrower than the glyph's artwork).
        var boxW = run.Width;
        var unit = SKMatrix.CreateScale(1f / boxW, 1f / run.Height);
        var total = SKMatrix.Concat(m.Value, unit);
        var pxPerUnit = (Dist(p[0], p[1]) / boxW + Dist(p[0], p[3]) / run.Height) * 0.5f;
        if (pxPerUnit <= 0.0001f) return;

        // Cull quads fully outside the target.
        var bounds = canvas.DeviceClipBounds;
        if (p.All(q => q.X < bounds.Left - 200) || p.All(q => q.X > bounds.Right + 200) || p.All(q => q.Y < bounds.Top - 200) || p.All(q => q.Y > bounds.Bottom + 200)) return;

        // Fast path: the word (with its crisp outline or offset shadow) is rasterized once into a cached alpha mask and
        // only tinted and warped per frame. Depth-of-field softness is approximated by fading, not blurring.
        var tint = Rgba(color);
        if (item.Style == TextStyle.Fill && item.Blur > 0.02f) tint = Rgba(color, Math.Max(0.35f, 1f - 0.25f * item.Blur) * color.W);
        if (WordMask(item, run, pxPerUnit, ss) is { } word)
        {
            canvas.Save();
            canvas.SetMatrix(SKMatrix.Concat(total, SKMatrix.CreateScale(1f / word.Scale, 1f / word.Scale)));
            using var tinted = new SKPaint { IsAntialias = true, FilterQuality = SKFilterQuality.Medium, Color = tint };
            canvas.DrawImage(word.Image, -word.Pad, -word.Pad, tinted);
            canvas.Restore();
            return;
        }

        canvas.Save();
        canvas.SetMatrix(total);
        using var paint = new SKPaint { IsAntialias = true, Color = tint };
        switch (item.Style)
        {
            case TextStyle.Outline:
                paint.Style = SKPaintStyle.Stroke; paint.StrokeWidth = OutlinePx * ss / pxPerUnit; paint.StrokeJoin = SKStrokeJoin.Round;
                break;
            case TextStyle.Shadow:
                var d = ShadowOffset(item) * ss / pxPerUnit;
                canvas.Translate(d, d);
                break;
        }
        canvas.DrawText(run.Blob, 0, -run.Ascent, paint);
        canvas.Restore();
    }

    // ---------------------------------------------------------------- Word cache

    private const float OutlinePx = 3f;     // crisp dark stroke: 1.5 px on each side of the glyph edge
    private const int MaxCachedWords = 700;
    private const int MaxMaskSide = 1536;

    private readonly record struct WordKey(string Text, LyricFont Font, bool Mono, TextStyle Style, int Bucket, int Offset);
    private sealed class WordEntry { public SKImage? Image; public float Scale; public float Pad; public long LastUsed; }
    private readonly record struct MaskRef(SKImage Image, float Scale, float Pad);
    private readonly Dictionary<WordKey, WordEntry> _wordCache = new();
    private long _frameNumber;

    private static float ShadowOffset(in DrawItem item) => MathF.Round(Math.Clamp(item.ShadowPx * 0.2f, 2f, 3f) * 2f) / 2f;

    /// <summary>
    /// Alpha mask of one word in one style, rasterized once per (word, font, style, size bucket) and then reused for every
    /// frame. The bucket's raster scale is at or above the on-screen scale, so the mask stays crisp and is only ever
    /// minified. Returns null when the word is too large to cache (it is drawn as vectors instead).
    /// </summary>
    private MaskRef? WordMask(in DrawItem item, TextRun run, float pxPerUnit, float ss)
    {
        var bucket = (int)Math.Ceiling(Math.Log(Math.Max(pxPerUnit, 0.05f)) / Math.Log(1.25));
        var scale = MathF.Pow(1.25f, bucket);
        var offset = item.Style == TextStyle.Shadow ? (int)(ShadowOffset(item) * 2) : 0;
        var key = new WordKey(item.Text!, _font, item.Mono, item.Style, bucket, offset);
        if (_wordCache.TryGetValue(key, out var hit))
        {
            hit.LastUsed = _frameNumber;
            return hit.Image is null ? null : new MaskRef(hit.Image, hit.Scale, hit.Pad);
        }

        var strokePx = OutlinePx * ss;
        var shadowPx = ShadowOffset(item) * ss;
        var pad = MathF.Ceiling(item.Style == TextStyle.Outline ? strokePx * 0.5f + 2 : item.Style == TextStyle.Shadow ? shadowPx + 2 : 2);
        var wPx = (int)Math.Ceiling(run.Width * scale + pad * 2);
        var hPx = (int)Math.Ceiling(run.Height * scale + pad * 2);
        var entry = new WordEntry { Scale = scale, Pad = pad, LastUsed = _frameNumber };
        if (wPx <= MaxMaskSide && hPx <= MaxMaskSide)
        {
            using var surface = SKSurface.Create(new SKImageInfo(wPx, hPx, SKColorType.Alpha8, SKAlphaType.Premul));
            if (surface != null)
            {
                var c = surface.Canvas;
                c.Clear(SKColors.Transparent);
                using var paint = new SKPaint { IsAntialias = true, Color = SKColors.White };
                var shift = item.Style == TextStyle.Shadow ? shadowPx : 0;
                c.Translate(pad + shift, pad + shift);
                c.Scale(scale);
                if (item.Style == TextStyle.Outline)
                {
                    paint.Style = SKPaintStyle.Stroke; paint.StrokeWidth = strokePx / scale; paint.StrokeJoin = SKStrokeJoin.Round;
                }
                c.DrawText(run.Blob!, 0, -run.Ascent, paint);
                c.Flush();
                entry.Image = surface.Snapshot();
            }
        }
        _wordCache[key] = entry;
        return entry.Image is null ? null : new MaskRef(entry.Image, scale, pad);
    }

    /// <summary>Drops masks not used for two seconds once the cache is large; resets it outright if it still overflows.</summary>
    private void TrimWordCache()
    {
        if (_wordCache.Count <= MaxCachedWords) return;
        var stale = _wordCache.Where(kv => _frameNumber - kv.Value.LastUsed > 120).Select(kv => kv.Key).ToList();
        foreach (var k in stale) { _wordCache[k].Image?.Dispose(); _wordCache.Remove(k); }
        if (_wordCache.Count <= MaxCachedWords * 3 / 2) return;
        foreach (var e in _wordCache.Values) e.Image?.Dispose();
        _wordCache.Clear();
    }

    private void DrawRibbon(SKCanvas canvas, in DrawItem item, Vector4 color, in CameraFrame cam, Vector2 center, float ss)
    {
        if (!Project(item.C0, cam, center, ss, out var a, out var za) || !Project(item.End, cam, center, ss, out var b, out var zb)) return;
        var wpx = Math.Max(0.6f, item.Size * cam.Focal / Math.Max((za + zb) * 0.5f, 1f) * ss);
        var additive = item.Layer == DrawLayer.Glow;
        var glow = item.Extra;
        if (glow > 0.05f && additive)
        {
            // Two stacked translucent strokes fake the falloff of the former blurred halo.
            using var halo = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeCap = SKStrokeCap.Round, StrokeWidth = wpx * (1.2f + glow * 1.8f),
                Color = Rgba(color, 0.14f * Math.Min(glow, 1.5f)), BlendMode = SKBlendMode.Plus };
            canvas.DrawLine(a, b, halo);
            halo.StrokeWidth = wpx * (0.8f + glow * 0.9f);
            canvas.DrawLine(a, b, halo);
        }
        using var core = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeCap = SKStrokeCap.Round, StrokeWidth = wpx, Color = Rgba(color),
            BlendMode = additive ? SKBlendMode.Plus : SKBlendMode.SrcOver };
        canvas.DrawLine(a, b, core);
    }

    private static SKShader RadialFalloff(float cx, float cy, float r, Vector4 c, Func<float, float> alphaAt)
    {
        const int N = 10;
        var colors = new SKColor[N + 1]; var pos = new float[N + 1];
        for (var i = 0; i <= N; i++) { var t = (float)i / N; pos[i] = t; colors[i] = Rgba(c, Math.Clamp(alphaAt(t), 0, 1)); }
        return SKShader.CreateRadialGradient(new SKPoint(cx, cy), Math.Max(r, 0.5f), colors, pos, SKShaderTileMode.Clamp);
    }

    private const int ProfileSide = 96;
    private readonly Dictionary<(bool Plume, int Exp), SKImage> _profiles = new();

    /// <summary>
    /// Radial alpha falloff of a soft sprite as a small 96x96 mask, built once. Large plumes and halos are then a single
    /// bilinear-upscaled textured quad instead of a per-pixel gradient shader over thousands of pixels.
    /// </summary>
    private SKImage Profile(bool plume, float exponent)
    {
        var q = (int)Math.Round(exponent * 2);
        if (_profiles.TryGetValue((plume, q), out var hit)) return hit;
        var e = q / 2f;
        using var bitmap = new SKBitmap(new SKImageInfo(ProfileSide, ProfileSide, SKColorType.Alpha8, SKAlphaType.Premul));
        var data = new byte[ProfileSide * ProfileSide];
        var half = ProfileSide / 2f;
        for (var y = 0; y < ProfileSide; y++)
            for (var x = 0; x < ProfileSide; x++)
            {
                var dx = (x + 0.5f) / half - 1; var dy = (y + 0.5f) / half - 1;
                var t = MathF.Sqrt(dx * dx + dy * dy);
                float v;
                if (t >= 1) v = 0;
                else if (plume) { var k = Math.Clamp((t - 0.30f) / 0.70f, 0f, 1f); k = k * k * (3 - 2 * k); v = 1 - k; }
                else v = MathF.Pow(1 - t, e);
                data[y * ProfileSide + x] = (byte)Math.Clamp(v * 255f + 0.5f, 0, 255);
            }
        System.Runtime.InteropServices.Marshal.Copy(data, 0, bitmap.GetPixels(), data.Length);
        return _profiles[(plume, q)] = SKImage.FromBitmap(bitmap);
    }

    private void DrawSprite(SKCanvas canvas, in DrawItem item, Vector4 color, in CameraFrame cam, Vector2 center, float ss)
    {
        if (!Project(item.C0, cam, center, ss, out var p, out var z)) return;
        var r = item.Size * cam.Focal / z * ss;
        if (r < 0.5f || r > 6000) return;
        var additive = item.Layer == DrawLayer.Glow;
        using var paint = new SKPaint { IsAntialias = true, BlendMode = additive ? SKBlendMode.Plus : SKBlendMode.SrcOver };
        switch (item.Kind)
        {
            case DrawKind.Glow:
            {
                // A cached low-resolution falloff mask, tinted and scaled up with linear filtering.
                paint.FilterQuality = SKFilterQuality.Medium;
                paint.Color = Rgba(color);
                canvas.DrawImage(Profile(false, Math.Max(item.Extra, 1.6f)), new SKRect(p.X - r, p.Y - r, p.X + r, p.Y + r), paint);
                break;
            }
            case DrawKind.Plume:
            {
                // Soft dark scrim: strength at the core, feathering smoothly to zero.
                var strength = item.Extra;
                var aspect = item.Stretch > 0.01f ? item.Stretch : 1f;
                canvas.Save();
                canvas.Translate(p.X, p.Y); canvas.Scale(aspect, 1); canvas.Translate(-p.X, -p.Y);
                paint.FilterQuality = SKFilterQuality.Medium;
                paint.Color = Rgba(new Vector4(color.X, color.Y, color.Z, 1), Math.Clamp(strength * color.W, 0, 1));
                canvas.DrawImage(Profile(true, 0), new SKRect(p.X - r, p.Y - r, p.X + r, p.Y + r), paint);
                canvas.Restore();
                break;
            }
            case DrawKind.Flare:
            {
                // Four-point star: soft core plus thin horizontal/vertical spikes and fainter diagonals.
                paint.Shader = RadialFalloff(p.X, p.Y, r * 0.35f, color, t => MathF.Pow(1 - t, 2.2f) * 0.9f);
                canvas.DrawCircle(p, r * 0.35f, paint);
                foreach (var (angle, len, thick, a) in new[] { (0f, 1f, 0.06f, 1f), (90f, 1f, 0.06f, 1f), (45f, 0.5f, 0.04f, 0.45f), (135f, 0.5f, 0.04f, 0.45f) })
                {
                    canvas.Save();
                    canvas.Translate(p.X, p.Y); canvas.RotateDegrees(angle); canvas.Scale(len * r, Math.Max(thick * r, 2.5f * ss));   // never thinner than ~2.5 px: sub-pixel spikes alias when the lens resamples
                    using var spike = new SKPaint { IsAntialias = true, BlendMode = SKBlendMode.Plus,
                        Shader = SKShader.CreateRadialGradient(SKPoint.Empty, 1f, new[] { Rgba(new Vector4(1, 1, 1, 1), color.W * a), Rgba(color, 0.0f) }, null, SKShaderTileMode.Clamp) };
                    canvas.DrawCircle(0, 0, 1, spike);
                    canvas.Restore();
                }
                break;
            }
        }
    }

    private void DrawPanel(SKCanvas canvas, in DrawItem item, Vector4 color, in CameraFrame cam, Vector2 center, float ss)
    {
        if (!Quad(item, cam, center, ss, out var p)) return;
        var m = Homography(p[0], p[1], p[2], p[3]);
        if (m is null) return;
        var aspect = Math.Max(item.Stretch, 0.01f);
        var total = SKMatrix.Concat(m.Value, SKMatrix.CreateScale(1f / aspect, 1f));      // panel space: (0..aspect, 0..1)
        var radius = Math.Max(item.Corner, 0.004f);
        var pxPerUnit = Dist(p[0], p[3]);
        canvas.Save();
        canvas.SetMatrix(total);
        var rect = new SKRect(0, 0, aspect, 1);
        var fillAlpha = color.W;
        using (var fill = new SKPaint { IsAntialias = true, Color = new SKColor((byte)(0.03f * 255), (byte)(0.035f * 255), (byte)(0.05f * 255), (byte)Math.Clamp(fillAlpha * 255, 0, 255)),
                   BlendMode = item.Layer == DrawLayer.Glow ? SKBlendMode.Plus : SKBlendMode.SrcOver })
        {
            if (item.Layer == DrawLayer.Glow) fill.Color = Rgba(color);
            canvas.DrawRoundRect(rect, radius, radius, fill);
        }
        if (item.Extra > 0.01f)
        {
            using var border = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 2.2f / Math.Max(pxPerUnit, 1f), Color = Rgba(color, 0.9f * item.Extra), BlendMode = SKBlendMode.Plus };
            using var glow = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 9f / Math.Max(pxPerUnit, 1f), Color = Rgba(color, 0.2f * item.Extra), BlendMode = SKBlendMode.Plus };
            canvas.DrawRoundRect(rect, radius, radius, glow);
            glow.StrokeWidth = 5f / Math.Max(pxPerUnit, 1f);
            canvas.DrawRoundRect(rect, radius, radius, glow);
            canvas.DrawRoundRect(rect, radius, radius, border);
        }
        canvas.Restore();
    }

    // ---------------------------------------------------------------- Lens

    private void DrawDomeBacking(SKCanvas canvas, LensParams lp, Vector3 hi, float alpha)
    {
        canvas.Save();
        canvas.Translate(lp.CenterX, lp.CenterY); canvas.Scale(lp.RadiusX, lp.RadiusY);
        var back = new Vector4(0.012f + hi.X * 0.035f, 0.016f + hi.Y * 0.035f, 0.026f + hi.Z * 0.035f, 1);
        using var paint = new SKPaint { IsAntialias = true,
            Shader = SKShader.CreateRadialGradient(SKPoint.Empty, 1f, new[] { Rgba(back, 0.60f * alpha), Rgba(back, 0.60f * alpha), Rgba(back, 0.88f * alpha) }, new[] { 0f, 0.35f, 1f }, SKShaderTileMode.Clamp) };
        canvas.DrawCircle(0, 0, 1, paint);
        canvas.Restore();
    }

    private const int MeshCols = 96, MeshRows = 64;

    /// <summary>
    /// Barrel lens as a textured mesh warp: each output grid vertex samples the supersampled scene at the inverse of
    /// n' = n * mag / sqrt(1 + k |n|^2). Red, green and blue are drawn additively through slightly different lenses
    /// (chromatic refraction). Piecewise-linear over a 96x64 grid, which rasterizes in a few milliseconds on the CPU.
    /// </summary>
    private void DrawLensed(SKCanvas canvas, SKImage image, LensParams lp, float ss, float alpha)
    {
        var channels = new (float R, float G, float B, float Off)[] { (1, 0, 0, -lp.Chroma), (0, 1, 0, 0), (0, 0, 1, lp.Chroma) };
        var vertexCount = (MeshCols + 1) * (MeshRows + 1);
        var indices = new ushort[MeshCols * MeshRows * 6];
        var ii = 0;
        for (var j = 0; j < MeshRows; j++)
            for (var i = 0; i < MeshCols; i++)
            {
                var a = (ushort)(j * (MeshCols + 1) + i); var b = (ushort)(a + 1); var c = (ushort)(a + MeshCols + 1); var d = (ushort)(c + 1);
                indices[ii++] = a; indices[ii++] = b; indices[ii++] = c; indices[ii++] = b; indices[ii++] = d; indices[ii++] = c;
            }
        using var shader = image.ToShader(SKShaderTileMode.Clamp, SKShaderTileMode.Clamp);
        using var clip = new SKPath();
        clip.AddOval(new SKRect(lp.CenterX - lp.RadiusX, lp.CenterY - lp.RadiusY, lp.CenterX + lp.RadiusX, lp.CenterY + lp.RadiusY));
        canvas.Save();
        canvas.ClipPath(clip, SKClipOperation.Intersect, true);
        foreach (var (cr, cg, cb, off) in channels)
        {
            var pos = new SKPoint[vertexCount]; var tex = new SKPoint[vertexCount];
            var kc = lp.K * (1 + off);
            var v = 0;
            for (var j = 0; j <= MeshRows; j++)
                for (var i = 0; i <= MeshCols; i++, v++)
                {
                    var nx = i / (float)MeshCols * 2 - 1; var ny = j / (float)MeshRows * 2 - 1;      // output n' in the unit square
                    var rho2 = nx * nx + ny * ny;
                    var inv = 1f / MathF.Sqrt(Math.Max(lp.Magnification * lp.Magnification - kc * rho2, 0.05f));
                    pos[v] = new SKPoint(lp.CenterX + nx * lp.RadiusX, lp.CenterY + ny * lp.RadiusY);
                    tex[v] = new SKPoint((lp.CenterX + nx * inv * lp.RadiusX) * ss, (lp.CenterY + ny * inv * lp.RadiusY) * ss);
                }
            using var verts = SKVertices.CreateCopy(SKVertexMode.Triangles, pos, tex, null, indices);
            var m = new float[]
            {
                cr, 0, 0, 0, 0,
                0, cg, 0, 0, 0,
                0, 0, cb, 0, 0,
                0.3333f, 0.3333f, 0.3333f, 0, 0,
            };
            using var filter = SKColorFilter.CreateColorMatrix(m);
            using var paint = new SKPaint { Shader = shader, ColorFilter = filter, IsAntialias = true, FilterQuality = SKFilterQuality.High,
                BlendMode = SKBlendMode.Plus, Color = SKColors.White.WithAlpha((byte)(alpha * 255)) };
            canvas.DrawVertices(verts, SKBlendMode.Modulate, paint);
        }
        canvas.Restore();
    }

    private void DrawRim(SKCanvas canvas, LensParams lp, Vector3 hi, float alpha)
    {
        var rim = new Vector4(hi.X + (1 - hi.X) * 0.55f, hi.Y + (1 - hi.Y) * 0.55f, hi.Z + (1 - hi.Z) * 0.55f, 1);
        var rect = new SKRect(lp.CenterX - lp.RadiusX, lp.CenterY - lp.RadiusY, lp.CenterX + lp.RadiusX, lp.CenterY + lp.RadiusY);
        using (var glow = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = lp.RadiusY * 0.09f, Color = Rgba(rim, 0.15f * alpha), BlendMode = SKBlendMode.Plus })
        {
            canvas.DrawOval(rect, glow);
            glow.StrokeWidth = lp.RadiusY * 0.045f;
            canvas.DrawOval(rect, glow);
        }
        using (var line = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 2.5f, Color = Rgba(rim, 0.65f * alpha), BlendMode = SKBlendMode.Plus })
            canvas.DrawOval(rect, line);
        // Specular crescent at the upper left.
        using var spec = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = lp.RadiusY * 0.035f, StrokeCap = SKStrokeCap.Butt, Color = Rgba(new Vector4(1, 1, 1, 1), 0.22f * alpha), BlendMode = SKBlendMode.Plus };
        var inset = new SKRect(rect.Left + 6, rect.Top + 6, rect.Right - 6, rect.Bottom - 6);
        using var path = new SKPath();
        path.AddArc(inset, 200, 70);
        canvas.DrawPath(path, spec);
    }
}
