using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace EdgeGlow.Lyrics;

/// <summary>
/// Devanagari / Gurmukhi / Arabic-Urdu to readable Latin ("Hinglish"). .NET has no ICU transliterator, so this
/// is table driven, with schwa deletion for the Indic scripts ("पल पल" gives "pal pal", "दिल" gives "dil").
/// Urdu written without vowel marks is approximate by nature (an "a" is assumed between consonants).
/// </summary>
public static class LyricRomanizer
{
    public static bool NeedsRomanizing(string s)
    {
        foreach (var c in s)
            if ((c >= 0x0900 && c <= 0x0DFF) || (c >= 0x0600 && c <= 0x077F)) return true;
        return false;
    }

    public static string Romanize(string text)
    {
        if (!NeedsRomanizing(text)) return text;
        var sb = new StringBuilder();
        var word = new StringBuilder();
        void Flush() { if (word.Length > 0) { sb.Append(RomanizeWord(word.ToString())); word.Clear(); } }
        foreach (var c in text)
        {
            if (char.IsWhiteSpace(c) || c == '।' || c == '॥') { Flush(); sb.Append(c == '।' || c == '॥' ? '.' : c); }
            else word.Append(c);
        }
        Flush();
        return sb.ToString().ToLowerInvariant();
    }

    private static string RomanizeWord(string w)
    {
        var first = w.FirstOrDefault(c => (c >= 0x0900 && c <= 0x0DFF) || (c >= 0x0600 && c <= 0x077F));
        if (first >= 0x0900 && first <= 0x097F) return Indic(w, Deva);
        if (first >= 0x0A00 && first <= 0x0A7F) return Indic(w, Guru);
        if (first >= 0x0600 && first <= 0x077F) return Arabic(w);
        return w;
    }

    // ---- Indic ----

    private sealed class Script
    {
        public Dictionary<char, string> Consonants = new();
        public Dictionary<char, string> IndependentVowels = new();
        public Dictionary<char, string> Matras = new();
        public Dictionary<char, string> Signs = new();      // anusvara etc: appended after the syllable
        public Dictionary<char, string> Digits = new();
        public char Virama, Nukta;
        public Dictionary<char, string> NuktaForms = new();
    }

    private static readonly Script Deva = new()
    {
        Consonants = Map("कk खkh गg घgh ङn चch छchh जj झjh ञn टt ठth डd ढdh णn तt थth दd धdh नn पp फf बb भbh मm यy रr लl वv शsh षsh सs हh ळl"),
        IndependentVowels = Map("अa आaa इi ईee उu ऊoo ऋri एe ऐai ओo औau ऑo"),
        Matras = Map("ाaa िi ीee ुu ूoo ृri ेe ैai ोo ौau ॉo"),
        Signs = Map("ंn ँn ःh"),
        Digits = Map("०0 १1 २2 ३3 ४4 ५5 ६6 ७7 ८8 ९9"),
        Virama = '्', Nukta = '़',
        NuktaForms = Map("कq खkh गgh जz डr ढrh फf"),
    };

    private static readonly Script Guru = new()
    {
        Consonants = Map("ਕk ਖkh ਗg ਘgh ਙn ਚch ਛchh ਜj ਝjh ਞn ਟt ਠth ਡd ਢdh ਣn ਤt ਥth ਦd ਧdh ਨn ਪp ਫf ਬb ਭbh ਮm ਯy ਰr ਲl ਵv ੜr ਸs ਹh"),
        IndependentVowels = Map("ਅa ਆaa ਇi ਈee ਉu ਊoo ਏe ਐai ਓo ਔau ੲi ੳu"),
        Matras = Map("ਾaa ਿi ੀee ੁu ੂoo ੇe ੈai ੋo ੌau"),
        Signs = Map("ਂn ੰn ਃh"),
        Digits = Map("੦0 ੧1 ੨2 ੩3 ੪4 ੫5 ੬6 ੭7 ੮8 ੯9"),
        Virama = '੍', Nukta = '਼',
        NuktaForms = Map("ਸsh ਖkh ਗgh ਜz ਫf"),
    };

    /// <summary>"कk खkh": each entry is one Indic character followed by its Latin form.</summary>
    private static Dictionary<char, string> Map(string spec)
    {
        var d = new Dictionary<char, string>();
        foreach (var token in spec.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            // Precomposed nukta letters (e.g. क़) are two code units in NFC-less input; key on the first char only when length matches.
            var i = 0;
            while (i < token.Length && !(token[i] < 0x80)) i++;
            if (i == 0 || i == token.Length) continue;
            d[token[0]] = token[i..];
        }
        return d;
    }

    private sealed class Unit
    {
        public string Cons = "";
        public string? Vowel;           // null: inherent 'a' (may be deleted)
        public bool Explicit;           // vowel written explicitly
        public bool Dead;               // virama: no vowel at all
        public string Tail = "";
        public bool InherentDeleted;
    }

    private static string Indic(string w, Script s)
    {
        // Normalize precomposed nukta letters (U+0958..095F) so the base + nukta route is used.
        w = w.Normalize(NormalizationForm.FormD);
        var units = new List<Unit>();
        var prefix = new StringBuilder();
        for (var i = 0; i < w.Length; i++)
        {
            var c = w[i];
            if (s.Consonants.TryGetValue(c, out var cons))
            {
                if (i + 1 < w.Length && w[i + 1] == s.Nukta && s.NuktaForms.TryGetValue(c, out var nf)) { cons = nf; i++; }
                units.Add(new Unit { Cons = cons });
            }
            else if (s.IndependentVowels.TryGetValue(c, out var iv)) units.Add(new Unit { Vowel = iv, Explicit = true });
            else if (s.Matras.TryGetValue(c, out var m)) { if (units.Count > 0) { units[^1].Vowel = m; units[^1].Explicit = true; } }
            else if (c == s.Virama) { if (units.Count > 0) { units[^1].Dead = true; } }
            else if (s.Signs.TryGetValue(c, out var sign)) { if (units.Count > 0) units[^1].Tail += sign; else prefix.Append(sign); }
            else if (s.Digits.TryGetValue(c, out var dg)) { units.Add(new Unit { Vowel = dg, Explicit = true }); }
            else if (c != s.Nukta) units.Add(new Unit { Vowel = c.ToString(), Explicit = true });   // punctuation inside a word keeps its place
        }
        // Schwa deletion: word-final, and medial in VC-CV position (right to left).
        for (var i = units.Count - 1; i >= 0; i--)
        {
            var u = units[i];
            if (u.Cons.Length == 0 || u.Explicit || u.Dead) continue;
            if (i == units.Count - 1) { u.InherentDeleted = true; continue; }
            var prevHasVowel = i > 0 && (units[i - 1].Explicit || (!units[i - 1].Dead && !units[i - 1].InherentDeleted));
            var next = units[i + 1];
            var nextHasVowel = next.Explicit || (!next.Dead && !next.InherentDeleted);
            if (i > 0 && prevHasVowel && nextHasVowel) u.InherentDeleted = true;
        }
        var sb = new StringBuilder(prefix.ToString());
        foreach (var u in units)
        {
            sb.Append(u.Cons);
            if (u.Vowel != null) sb.Append(u.Vowel);
            else if (u.Cons.Length > 0 && !u.Dead && !u.InherentDeleted) sb.Append('a');
            sb.Append(u.Tail);
        }
        return sb.ToString();
    }

    // ---- Arabic / Urdu ----

    private static readonly Dictionary<char, string> Ar = new()
    {
        ['ا'] = "a", ['آ'] = "aa", ['ب'] = "b", ['پ'] = "p", ['ت'] = "t", ['ٹ'] = "t", ['ث'] = "s", ['ج'] = "j", ['چ'] = "ch", ['ح'] = "h", ['خ'] = "kh",
        ['د'] = "d", ['ڈ'] = "d", ['ذ'] = "z", ['ر'] = "r", ['ڑ'] = "r", ['ز'] = "z", ['ژ'] = "zh", ['س'] = "s", ['ش'] = "sh", ['ص'] = "s", ['ض'] = "z",
        ['ط'] = "t", ['ظ'] = "z", ['ع'] = "a", ['غ'] = "gh", ['ف'] = "f", ['ق'] = "q", ['ک'] = "k", ['ك'] = "k", ['گ'] = "g", ['ل'] = "l", ['م'] = "m",
        ['ن'] = "n", ['ں'] = "n", ['و'] = "o", ['ہ'] = "h", ['ھ'] = "h", ['ه'] = "h", ['ء'] = "'", ['ی'] = "ee", ['ي'] = "y", ['ے'] = "e", ['ئ'] = "y", ['ۓ'] = "e",
        ['َ'] = "a", ['ِ'] = "i", ['ُ'] = "u", ['ً'] = "an", ['ٰ'] = "a",
    };
    private static readonly HashSet<char> ArVowelLetters = new() { 'ا', 'آ', 'و', 'ی', 'ے', 'ع', 'ي', 'ئ', 'ۓ', 'َ', 'ِ', 'ُ', 'ً', 'ٰ' };

    private static string Arabic(string w)
    {
        var sb = new StringBuilder();
        char? prevConsonant = null;
        foreach (var c in w)
        {
            if (c == 'ّ' || c == 'ْ' || c == '‌') continue;
            if (!Ar.TryGetValue(c, out var latin)) { sb.Append(c); prevConsonant = null; continue; }
            var isVowel = ArVowelLetters.Contains(c);
            if (!isVowel && prevConsonant != null) sb.Append('a');   // unwritten short vowel between two consonants
            sb.Append(latin);
            prevConsonant = isVowel ? null : c;
        }
        return sb.ToString();
    }
}
