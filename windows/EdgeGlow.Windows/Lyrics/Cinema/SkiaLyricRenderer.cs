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
    private const float LensSupersample = 1.3f;
    private SKSurface? _lensSurface;
    private int _lensW, _lensH;
    private LyricFont _font = LyricFont.SfPro;

    public void Dispose()
    {
        _lensSurface?.Dispose();
        foreach (var image in _emojiImages.Values) image.Dispose();
    }

    // ---------------------------------------------------------------- Entry

    public void Render(SKCanvas canvas, DrawList list, in CameraFrame cam, float w, float h, double focusY, LyricFont font,
                       LensParams? lens, Vector3 highlight, float alpha = 1)
    {
        _font = font;
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
        foreach (var layer in new[] { DrawLayer.Back, DrawLayer.Body, DrawLayer.Glow, DrawLayer.Top })
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

        canvas.Save();
        canvas.SetMatrix(total);
        using var paint = new SKPaint { IsAntialias = true, Color = Rgba(color) };
        switch (item.Style)
        {
            case TextStyle.Outline:
                paint.Style = SKPaintStyle.Stroke; paint.StrokeWidth = 3f * ss / pxPerUnit; paint.StrokeJoin = SKStrokeJoin.Round;
                break;
            case TextStyle.Shadow:
                paint.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, Math.Max(0.5f, item.ShadowPx * ss * 0.5f / pxPerUnit), true);
                break;
            default:
                if (item.Blur > 0.02f) paint.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 0.77f * item.Blur, true);
                break;
        }
        canvas.DrawText(run.Blob, 0, -run.Ascent, paint);
        canvas.Restore();
    }

    private void DrawRibbon(SKCanvas canvas, in DrawItem item, Vector4 color, in CameraFrame cam, Vector2 center, float ss)
    {
        if (!Project(item.C0, cam, center, ss, out var a, out var za) || !Project(item.End, cam, center, ss, out var b, out var zb)) return;
        var wpx = Math.Max(0.6f, item.Size * cam.Focal / Math.Max((za + zb) * 0.5f, 1f) * ss);
        var additive = item.Layer == DrawLayer.Glow;
        var glow = item.Extra;
        if (glow > 0.05f && additive)
        {
            using var halo = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeCap = SKStrokeCap.Round, StrokeWidth = wpx * (1.2f + glow * 1.8f),
                Color = Rgba(color, 0.32f * Math.Min(glow, 1.5f)), BlendMode = SKBlendMode.Plus, MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, wpx * 0.9f + 1) };
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
                var e = Math.Max(item.Extra, 1.6f);
                paint.Shader = RadialFalloff(p.X, p.Y, r, color, t => MathF.Pow(1 - t, e) * color.W / Math.Max(color.W, 0.0001f));
                paint.Color = SKColors.White;
                canvas.DrawCircle(p, r, paint);
                break;
            }
            case DrawKind.Plume:
            {
                // Soft dark scrim: strength at the core, feathering smoothly to zero.
                var strength = item.Extra;
                var aspect = item.Stretch > 0.01f ? item.Stretch : 1f;
                canvas.Save();
                canvas.Translate(p.X, p.Y); canvas.Scale(aspect, 1); canvas.Translate(-p.X, -p.Y);
                paint.Shader = RadialFalloff(p.X, p.Y, r, new Vector4(color.X, color.Y, color.Z, 1), t =>
                {
                    var s = Math.Clamp((t - 0.30f) / 0.70f, 0f, 1f); s = s * s * (3 - 2 * s);
                    return strength * color.W * (1 - s);
                });
                canvas.DrawCircle(p, r, paint);
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
            using var glow = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 9f / Math.Max(pxPerUnit, 1f), Color = Rgba(color, 0.35f * item.Extra), BlendMode = SKBlendMode.Plus,
                MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 4f / Math.Max(pxPerUnit, 1f)) };
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
        using (var glow = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = lp.RadiusY * 0.09f, Color = Rgba(rim, 0.30f * alpha),
                   MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, lp.RadiusY * 0.025f), BlendMode = SKBlendMode.Plus })
            canvas.DrawOval(rect, glow);
        using (var line = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 2.5f, Color = Rgba(rim, 0.65f * alpha), BlendMode = SKBlendMode.Plus })
            canvas.DrawOval(rect, line);
        // Specular crescent at the upper left.
        using var spec = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = lp.RadiusY * 0.035f, StrokeCap = SKStrokeCap.Butt, Color = Rgba(new Vector4(1, 1, 1, 1), 0.28f * alpha),
            MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, lp.RadiusY * 0.03f), BlendMode = SKBlendMode.Plus };
        var inset = new SKRect(rect.Left + 6, rect.Top + 6, rect.Right - 6, rect.Bottom - 6);
        using var path = new SKPath();
        path.AddArc(inset, 200, 70);
        canvas.DrawPath(path, spec);
    }
}
