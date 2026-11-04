using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Numerics;
using SkiaSharp;

namespace EdgeGlow.Lyrics;

/// <summary>
/// Renders every lyric style to PNG over a chosen backdrop (pure white, a light-mode browser page, or a bright gradient)
/// from a synthetic song full of semantic trigger words. Used to verify legibility without a display attached.
/// </summary>
public static class StylePreviews
{
    private static readonly string[] Lines =
    {
        "Driving fast in my car", "Crashing through the stars", "My heart is on fire",
        "Thunder in the night, we cry in the rain!", "Feel the bass shake the sky", "Hold me close and never let go",
    };

    public static TimedLyrics Song()
    {
        var words = new List<TimedWord>(); var groups = new List<List<TimedWord>>();
        var t = 1.0;
        for (var li = 0; li < Lines.Length; li++)
        {
            var group = new List<TimedWord>();
            foreach (var token in Lines[li].Split(' '))
            {
                var isLong = token.StartsWith("fire") || token.StartsWith("rain");
                var w = new TimedWord(words.Count, token, t, t + (isLong ? 1.1 : 0.4), li);
                words.Add(w); group.Add(w);
                t += isLong ? 1.15 : 0.46;
            }
            groups.Add(group);
            t += 0.7;
        }
        return new TimedLyrics { Tier = LyricTier.Interpolated, Words = words, Groups = groups, Source = "preview" };
    }

    public static void Run(string outputDir, string background = "white", LyricFont font = LyricFont.SfPro, LyricStyle[]? only = null, int width = 1920, int height = 1080)
    {
        Directory.CreateDirectory(outputDir);
        var lyrics = Song();
        var theme = new LyricTheme(font, new Vector4(0.30f, 0.88f, 1.0f, 1), new Vector4(1.0f, 0.36f, 0.82f, 1), 1);
        double Start(string text) => lyrics.Words.First(w => w.Text.StartsWith(text)).Start;
        var captures = new (string Label, double At)[]
        {
            ("1-car", Start("car") + 0.25), ("2-crashing", Start("Crashing") + 0.18), ("3-stars", Start("stars") + 0.3),
            ("4-heart", Start("heart") + 0.15), ("5-fire", Start("fire") + 0.45), ("6-bass", Start("bass") + 0.2),
        };
        foreach (var style in only ?? Enum.GetValues<LyricStyle>())
        {
            using var director = new LyricsDirector();
            var t = 0.0; const double step = 1.0 / 60;
            foreach (var (label, at) in captures)
            {
                Scene3D? scene = null; SceneInput? input = null;
                while (t < at + step)
                {
                    input = MakeInput(lyrics, theme, width, height, t);
                    scene = director.Advance(input, style);
                    t += step;
                }
                using var surface = SKSurface.Create(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
                var canvas = surface.Canvas;
                DrawBackdrop(canvas, background, width, height);
                director.Render(canvas, input!, scene!);
                canvas.Flush();
                using var image = surface.Snapshot();
                using var data = image.Encode(SKEncodedImageFormat.Png, 100);
                var path = Path.Combine(outputDir, $"{style}-{label}.png");
                File.WriteAllBytes(path, data.ToArray());
                Console.WriteLine($"wrote {path}");
            }
        }
    }

    private static SceneInput MakeInput(TimedLyrics lyrics, LyricTheme theme, int w, int h, double t)
    {
        const double beat = 0.5;
        var phase = (t / beat) % 1;
        var bass = Math.Exp(-phase * 5);
        return new SceneInput
        {
            Lyrics = lyrics, Pos = t, Theme = theme, Width = w, Height = h, Bass = bass,
            Vocal = 0.5 + 0.3 * Math.Sin(t * 2.3), Velocity = 0.5 + 0.4 * Math.Sin(t * 3), Time = t, FocusY = 0.5,
        };
    }

    private static void DrawBackdrop(SKCanvas canvas, string kind, int w, int h)
    {
        switch (kind)
        {
            case "gradient":
                using (var paint = new SKPaint { Shader = SKShader.CreateLinearGradient(new SKPoint(0, h), new SKPoint(w, 0),
                    new[] { new SKColor(247, 240, 209), new SKColor(168, 214, 250), new SKColor(252, 199, 168) }, new[] { 0f, 0.5f, 1f }, SKShaderTileMode.Clamp) })
                    canvas.DrawRect(0, 0, w, h, paint);
                break;
            case "browser":
                canvas.Clear(SKColors.White);
                using (var bar = new SKPaint { Color = new SKColor(241, 243, 244) }) canvas.DrawRect(0, 0, w, 96, bar);
                using (var pill = new SKPaint { Color = SKColors.White, IsAntialias = true }) canvas.DrawRoundRect(260, 26, w - 520, 44, 22, 22, pill);
                using (var text = new SKPaint { Color = new SKColor(218, 220, 224), IsAntialias = true })
                {
                    var rnd = new Random(3);
                    for (var y = 150; y < h - 40; y += 34)
                        canvas.DrawRoundRect(140, y, rnd.Next(520, w - 420), 14, 7, 7, text);
                }
                using (var head = new SKPaint { Color = new SKColor(32, 33, 36), IsAntialias = true }) canvas.DrawRoundRect(140, 118, 640, 22, 8, 8, head);
                break;
            default:
                canvas.Clear(SKColors.White);
                break;
        }
    }
}
