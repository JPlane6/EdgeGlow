using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;

namespace EdgeGlow.Lyrics;

public enum Archetype { None, Velocity, Impact, Fire, Heart, Tears, Cosmic, Vibe }

public struct SemanticTag
{
    public Archetype Archetype;
    public string? Symbol;
    public char? Punct;
    public string Lemma;
}

/// <summary>Per-frame modifiers applied to a word.</summary>
public struct WordMod
{
    public Vector2 Scale;
    public Vector3 Offset;          // in word-height units
    public float Roll;
    public float Tracking;
    public Vector4 Glow;            // rgb + intensity of the bloom behind the word
    public static WordMod Identity => new() { Scale = Vector2.One, Tracking = 1 };
}

public struct PropMod
{
    public Vector3 Offset;
    public float Scale;
    public float Roll;
    public float Alpha;
    public static PropMod Identity => new() { Scale = 1, Alpha = 1 };
}

/// <summary>
/// The smart choreography layer: tags every word with a kinetic archetype and an icon, and acts it out with
/// restrained accents (soft bloom on warm / cosmic words, a slow camera nudge, a spring-scaled active word).
/// </summary>
public sealed class SemanticKineticEngine
{
    public List<SemanticTag> Tags { get; private set; } = new();
    private int _lastActive = -1;

    private struct Flare { public Vector3 Pos; public float Size, Life, Age; public Vector4 Color; }
    private readonly List<Flare> _flares = new();

    public static readonly Vector4 Warm = new(1.0f, 0.55f, 0.14f, 1);
    public static readonly Vector4 Crimson = new(1.0f, 0.16f, 0.38f, 1);
    public static readonly Vector4 Water = new(0.55f, 0.82f, 1.0f, 1);

    public void Reset() { _lastActive = -1; _flares.Clear(); }

    // ---- Tagging ----

    public void Prepare(TimedLyrics lyrics)
    {
        Reset();
        Tags = lyrics.Words.Select(w => Tag(w.Text)).ToList();
    }

    private static IEnumerable<string> Candidates(string cleaned)
    {
        yield return cleaned;
        if (cleaned.EndsWith("in'")) yield return cleaned[..^3] + "ing";
        foreach (var suffix in new[] { "ing", "ed", "es", "s", "ly", "er", "est" })
        {
            if (!cleaned.EndsWith(suffix) || cleaned.Length <= suffix.Length + 2) continue;
            var stem = cleaned[..^suffix.Length];
            yield return stem;
            yield return stem + "e";
            if (stem.Length > 2 && stem[^1] == stem[^2]) yield return stem[..^1];
            if (suffix == "ed" || suffix == "es") yield return stem + "y";
        }
    }

    public static SemanticTag Tag(string raw)
    {
        var tag = new SemanticTag { Lemma = "" };
        var trimmed = raw.Trim();
        if (trimmed.EndsWith('!')) tag.Punct = '!'; else if (trimmed.EndsWith('?')) tag.Punct = '?';
        var cleaned = new string(trimmed.ToLowerInvariant().Where(char.IsLetter).ToArray());
        if (cleaned.Length < 2) return tag;
        foreach (var c in Candidates(cleaned))
        {
            foreach (var (archetype, words) in LexiconData.All)
            {
                if (!words.Contains(c)) continue;
                tag.Archetype = archetype; tag.Lemma = c;
                tag.Symbol = LexiconData.Glyphs.GetValueOrDefault(c) ?? LexiconData.Glyphs.GetValueOrDefault(cleaned) ?? LexiconData.DefaultGlyph.GetValueOrDefault(archetype);
                return tag;
            }
        }
        tag.Lemma = cleaned;
        return tag;
    }

    // ---- Events ----

    public readonly record struct Anchor(Vector3 Center, float HalfWidth, float Unit);

    public void Update(SceneInput input, double dt, Func<int, Anchor?> anchor, CinematicCamera3D camera)
    {
        for (var i = _flares.Count - 1; i >= 0; i--)
        {
            var f = _flares[i]; f.Age += (float)dt;
            if (f.Age >= f.Life) _flares.RemoveAt(i); else _flares[i] = f;
        }
        var activeOpt = input.ActiveWord;
        if (activeOpt is not int active || active >= Tags.Count) { _lastActive = activeOpt ?? -1; return; }
        var word = input.Lyrics.Words[active];
        var tag = Tags[active];
        var age = Math.Max(0, input.Pos - word.Start);
        if (active != _lastActive)
        {
            _lastActive = active;
            if (anchor(active) is { } a) Trigger(tag, a, camera);
        }
        if (word.Duration > 0.8 && age > 0.1) camera.Kick(dolly: -0.01 * dt * 60);
    }

    private void Trigger(SemanticTag tag, Anchor a, CinematicCamera3D camera)
    {
        switch (tag.Archetype)
        {
            case Archetype.Velocity: camera.Kick(dolly: 0.12, yaw: -0.012); break;
            case Archetype.Impact: camera.Kick(dolly: 0.18, pitch: 0.012); break;
            case Archetype.Fire: AddFlare(a.Center, a.Unit * 2.6f, 1.0f, Warm); break;
            case Archetype.Heart: case Archetype.Tears: camera.Kick(dolly: 0.06); break;
            case Archetype.Cosmic: AddFlare(a.Center + new Vector3(0, a.Unit * 0.2f, 0), a.Unit * 3.0f, 1.2f, new Vector4(0.75f, 0.88f, 1, 1)); break;
        }
    }

    private void AddFlare(Vector3 p, float size, float life, Vector4 color) => _flares.Add(new Flare { Pos = p, Size = size, Life = life, Color = color });

    /// <summary>Spring step response (stiffness 220, damping 24): fast, no visible overshoot.</summary>
    public static double Spring(double t)
    {
        if (t <= 0) return 0;
        var w = Math.Sqrt(220.0); var z = 24.0 / (2 * w);
        if (z >= 1) { var e = Math.Exp(-w * t); return 1 - e * (1 + w * t); }
        var wd = w * Math.Sqrt(1 - z * z);
        return 1 - Math.Exp(-z * w * t) * (Math.Cos(wd * t) + z * w / wd * Math.Sin(wd * t));
    }

    public WordMod WordMod(int index, SceneInput input, bool isActive)
    {
        var m = Cinema_WordModIdentity();
        if (index < 0 || index >= Tags.Count || !isActive) return m;
        var word = input.Lyrics.Words[index]; var tag = Tags[index];
        var age = (float)Math.Max(0, input.Pos - word.Start);
        var k = (float)Spring(age);
        m.Scale = new Vector2(1 + 0.12f * k);
        m.Offset.Z = -0.03f * k;
        m.Glow = tag.Archetype switch
        {
            Archetype.Heart or Archetype.Tears => new Vector4(Crimson.X, Crimson.Y, Crimson.Z, 0.28f),
            Archetype.Fire => new Vector4(Warm.X, Warm.Y, Warm.Z, 0.28f),
            Archetype.Cosmic => new Vector4(0.6f, 0.78f, 1, 0.24f),
            _ => default,
        };
        if (word.Duration > 0.8) m.Tracking = 1 + 0.04f * (float)Math.Min(1, age / word.Duration);
        return m;
    }
    private static WordMod Cinema_WordModIdentity() => Lyrics.WordMod.Identity;

    public PropMod PropMod(int index, SceneInput input)
    {
        var p = Lyrics.PropMod.Identity;
        if (index < 0 || index >= Tags.Count) return p;
        var age = Math.Max(0, input.Pos - input.Lyrics.Words[index].Start);
        p.Scale = (float)(0.5 + 0.5 * Math.Min(1, Math.Max(0, Spring(age))));
        return p;
    }

    public Vector4 Tint(int index, Vector4 fallback)
    {
        if (index < 0 || index >= Tags.Count) return fallback;
        return Tags[index].Archetype switch
        {
            Archetype.Heart => Crimson, Archetype.Tears => Water, Archetype.Fire => Warm,
            Archetype.Velocity => new Vector4(1, 1, 1, 1), Archetype.Impact => new Vector4(1, 0.95f, 0.8f, 1),
            _ => fallback,
        };
    }

    public void Draw(DrawList list, in CameraFrame cam)
    {
        foreach (var f in _flares)
        {
            var k = f.Age / f.Life; var fade = 1 - k;
            var c = f.Color; c.W = fade * Math.Min(1, k * 8);
            list.Sprite(DrawKind.Flare, f.Pos, f.Size * (0.7f + 0.5f * MathF.Sin(k * MathF.PI)), c, 0, 0, DrawLayer.Glow, cam);
        }
    }
}
