using System;
using System.Collections.Generic;
using System.Linq;
using SkiaSharp;

namespace EdgeGlow;

/// <summary>Pulls a vivid primary/secondary color pair out of album art (port of ColorExtractor.palette).</summary>
public static class ColorExtractor
{
    private const int Side = 32;
    private const int BucketCount = 12;

    private struct HueBucket
    {
        public double Weight, HueX, HueY, Saturation, Brightness;
        public int Count;
    }

    /// <summary>Returns null when the artwork has no usable color (e.g. grayscale covers).</summary>
    public static (RgbColor Primary, RgbColor Secondary)? Palette(byte[] encodedImage)
    {
        using var decoded = SKBitmap.Decode(encodedImage);
        if (decoded == null) return null;

        // Normalize whatever we downloaded by redrawing it into a buffer we own with a fixed RGBA layout.
        var info = new SKImageInfo(Side, Side, SKColorType.Rgba8888, SKAlphaType.Premul);
        using var small = new SKBitmap(info);
        using (var canvas = new SKCanvas(small))
        {
            canvas.Clear(SKColors.Transparent);
            using var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium, IsAntialias = true };
            canvas.DrawBitmap(decoded, new SKRect(0, 0, Side, Side), paint);
        }
        var pixels = small.Bytes;

        var buckets = new HueBucket[BucketCount];
        for (var offset = 0; offset + 3 < pixels.Length; offset += 4)
        {
            var alpha = pixels[offset + 3] / 255.0;
            if (alpha <= 0.5) continue;
            // Un-premultiply.
            var r = Math.Min(pixels[offset] / 255.0 / alpha, 1);
            var g = Math.Min(pixels[offset + 1] / 255.0 / alpha, 1);
            var b = Math.Min(pixels[offset + 2] / 255.0 / alpha, 1);
            var (h, s, v) = Hsb(r, g, b);

            // Skip near-black, near-white and washed-out pixels.
            if (!(v > 0.18 && s > 0.25 && !(v > 0.92 && s < 0.15))) continue;

            var index = Math.Min((int)(h * BucketCount), BucketCount - 1);
            var weight = s * v;
            var angle = h * 2 * Math.PI;
            buckets[index].Weight += weight;
            buckets[index].HueX += Math.Cos(angle) * weight;
            buckets[index].HueY += Math.Sin(angle) * weight;
            buckets[index].Saturation += s * weight;
            buckets[index].Brightness += v * weight;
            buckets[index].Count++;
        }

        var ranked = Enumerable.Range(0, BucketCount).OrderByDescending(i => buckets[i].Weight).ToList();
        var primaryIndex = ranked[0];
        var primaryBucket = buckets[primaryIndex];
        if (primaryBucket.Count < 3) return null;

        var primaryHsb = Average(primaryBucket);
        var primary = Vivid(primaryHsb);

        // Secondary: the strongest bucket at least 60 degrees away, so the gradient actually has contrast.
        int? secondaryIndex = null;
        foreach (var index in ranked.Skip(1))
        {
            var distance = Math.Abs(index - primaryIndex);
            var circular = Math.Min(distance, BucketCount - distance);
            if (circular >= 2 && buckets[index].Count >= 2 && buckets[index].Weight >= primaryBucket.Weight * 0.08)
            {
                secondaryIndex = index;
                break;
            }
        }

        RgbColor secondary;
        if (secondaryIndex.HasValue)
        {
            secondary = Vivid(Average(buckets[secondaryIndex.Value]));
        }
        else
        {
            // Monochromatic art: derive an analogous hue so the rim still shimmers.
            var shifted = (primaryHsb.H + 0.12) % 1;
            secondary = Vivid((shifted, primaryHsb.S, primaryHsb.V));
        }
        return (primary, secondary);
    }

    private static (double H, double S, double V) Average(HueBucket bucket)
    {
        var hue = Math.Atan2(bucket.HueY, bucket.HueX) / (2 * Math.PI);
        if (hue < 0) hue += 1;
        return (hue, bucket.Saturation / bucket.Weight, bucket.Brightness / bucket.Weight);
    }

    /// <summary>Pushes a color into neon territory so the glow never looks muddy.</summary>
    private static RgbColor Vivid((double H, double S, double V) hsb) =>
        Rgb(hsb.H, Math.Max(hsb.S, 0.85), Math.Max(hsb.V, 0.95));

    private static (double H, double S, double V) Hsb(double r, double g, double b)
    {
        var max = Math.Max(r, Math.Max(g, b));
        var min = Math.Min(r, Math.Min(g, b));
        var delta = max - min;
        var h = 0.0;
        if (delta > 0)
        {
            if (max == r) h = ((g - b) / delta) % 6;
            else if (max == g) h = (b - r) / delta + 2;
            else h = (r - g) / delta + 4;
            h /= 6;
            if (h < 0) h += 1;
        }
        var s = max == 0 ? 0 : delta / max;
        return (h, s, max);
    }

    private static RgbColor Rgb(double h, double s, double v)
    {
        var sector = (h * 6) % 6;
        var c = v * s;
        var x = c * (1 - Math.Abs(sector % 2 - 1));
        var m = v - c;
        (double r, double g, double b) = (int)sector switch
        {
            0 => (c, x, 0.0),
            1 => (x, c, 0.0),
            2 => (0.0, c, x),
            3 => (0.0, x, c),
            4 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        return new RgbColor(r + m, g + m, b + m);
    }
}
