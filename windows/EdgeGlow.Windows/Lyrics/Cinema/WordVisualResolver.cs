using System;
using System.Collections.Generic;
using System.Linq;

namespace EdgeGlow.Lyrics;

/// <summary>
/// Word to icon. Step 1 normalizes contractions ("you're" gives "youre"); tier 1 is the curated table (~250 English
/// words plus ~170 Hinglish words); symbol names are shown as Segoe UI Emoji. (The macOS CoreGlyphs and NLEmbedding
/// tiers depend on Apple frameworks and have no Windows counterpart.)
/// </summary>
public static class WordVisualResolver
{
    private static readonly Dictionary<string, string> Table = Build();

    private static Dictionary<string, string> Build()
    {
        var d = new Dictionary<string, string>();
        void Add(string words, string emoji) { foreach (var w in words.Split(' ', StringSplitOptions.RemoveEmptyEntries)) d[w] = emoji; }
        foreach (var (words, sym) in LexiconData.Hinglish) if (LexiconData.SymbolEmoji.TryGetValue(sym, out var e)) Add(words, e);
        foreach (var (kind, words, value) in LexiconData.Curated)
        {
            if (kind == "e") Add(words, value);
            else if (LexiconData.SymbolEmoji.TryGetValue(value, out var e)) Add(words, e);
        }
        return d;
    }

    public static string Normalize(string s)
    {
        var t = s.ToLowerInvariant().Replace('’', '\'').Replace('‘', '\'').Replace("'", "");
        return new string(t.Where(c => char.IsLetterOrDigit(c)).ToArray());
    }

    public static string? SymbolToEmoji(string? symbol) =>
        symbol != null && LexiconData.SymbolEmoji.TryGetValue(symbol, out var e) ? e : null;

    public static string? Visual(string rawWord)
    {
        var token = Normalize(rawWord);
        if (token.Length < 2) return null;
        if (Table.TryGetValue(token, out var v)) return v;
        foreach (var suffix in new[] { "ing", "ed", "es", "s", "ly", "er" })
        {
            if (!token.EndsWith(suffix) || token.Length <= suffix.Length + 2) continue;
            var stem = token[..^suffix.Length];
            if (Table.TryGetValue(stem, out v)) return v;
            if (Table.TryGetValue(stem + "e", out v)) return v;
            if (stem.Length > 2 && stem[^1] == stem[^2] && Table.TryGetValue(stem[..^1], out v)) return v;
        }
        return null;
    }
}
