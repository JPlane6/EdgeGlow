using System;
using System.Linq;
using EdgeGlow.Lyrics;

// usage: LyricPreview <outputDir> [white|browser|gradient] [styleName ...]
//        LyricPreview --test-lyrics     (fetch + romanize the Hindi / Punjabi test tracks)
if (args.Length > 0 && args[0] == "--test-lyrics")
{
    var cases = new (string Title, string Artist)[]
    {
        ("Pal Pal", "Afusic"), ("Tauba Tauba", "Karan Aujla"), ("Tum Hi Ho", "Arijit Singh"),
        ("Kesariya (From \"Brahmastra\") [Official Video]", "Arijit Singh, Pritam, Amitabh Bhattacharya - T-Series"),
    };
    var fetcher = new LyricsFetcher();
    foreach (var (title, artist) in cases)
    {
        var clean = LyricSanitizer.Sanitize(title, artist);
        var result = await fetcher.FetchAsync(title, artist, 0);
        if (result.Lyrics is { } l)
        {
            var lines = Enumerable.Range(0, Math.Min(3, l.Groups.Count)).Select(i => LyricRomanizer.Romanize(l.LineText(i)));
            Console.WriteLine($"OK   \"{title}\" -> \"{clean.Title}\" / \"{clean.Artist}\" [{l.Source}, {l.Groups.Count} lines]\n     {string.Join(" | ", lines)}");
        }
        else Console.WriteLine($"{result.Outcome,-5}\"{title}\" -> \"{clean.Title}\" / \"{clean.Artist}\"");
    }
    foreach (var s in new[] { "पल पल दिल के पास", "तुम ही हो", "ਤੇਰੇ ਬਿਨਾ ਦਿਲ", "پل پل", "बारिश में सपना" })
        Console.WriteLine($"romanize  {s}  ->  {LyricRomanizer.Romanize(s)}");
    return;
}
var dir = args.Length > 0 ? args[0] : "previews";
var bg = args.Length > 1 ? args[1] : "white";
var styles = args.Skip(2).Select(a => Enum.Parse<LyricStyle>(a, true)).ToArray();
StylePreviews.Run(dir, bg, LyricFont.SfPro, styles.Length > 0 ? styles : null);
