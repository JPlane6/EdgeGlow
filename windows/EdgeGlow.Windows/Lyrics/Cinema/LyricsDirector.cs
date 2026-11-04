using System;
using System.Numerics;
using SkiaSharp;

namespace EdgeGlow.Lyrics;

/// <summary>Owns one scene per style, advances physics, and draws a frame with the Skia renderer.</summary>
public sealed class LyricsDirector : IDisposable
{
    private readonly SemanticKineticEngine _engine = new();
    private readonly DrawList _list = new();
    private readonly SkiaLyricRenderer _renderer = new();
    private Scene3D? _scene; private LyricStyle _style;
    private string _signature = "";
    private double? _lastTime;

    private static Scene3D Make(LyricStyle s) => s switch
    {
        LyricStyle.Ship => new WallScene3D(false, false),
        LyricStyle.Visual => new WallScene3D(true, false),
        LyricStyle.Fisheye => new WallScene3D(false, true),
        LyricStyle.FisheyeVisual => new WallScene3D(true, true),
        LyricStyle.Constellation => new ConstellationScene3D(false),
        LyricStyle.Constellation3D => new ConstellationScene3D(false, true),
        LyricStyle.HyperShip3D => new WallScene3D(true, false, true),
        LyricStyle.OrbitalWeb3D => new OrbitalWebScene3D(false),
        LyricStyle.Branches => new BranchesScene3D(false),
        LyricStyle.Web => new WebScene3D(false),
        LyricStyle.CodestyleVisual => new CodeScene3D(true),
        _ => new ConstellationScene3D(false),
    };

    public void Dispose() => _renderer.Dispose();

    /// <summary>Advances physics to <c>input.Time</c> (no drawing).</summary>
    public Scene3D Advance(SceneInput input, LyricStyle style)
    {
        if (_scene == null || _style != style)
        {
            _scene = Make(style); _style = style; _scene.Engine = _engine; _signature = ""; _lastTime = null;
        }
        var sig = $"{input.Lyrics.Words.Count}|{input.Lyrics.FirstOnset}|{input.Lyrics.LastEnd}";
        if (sig != _signature)
        {
            _signature = sig;
            _engine.Prepare(input.Lyrics);
            _scene.Reset();
            _lastTime = null;
        }
        var dt = _lastTime is double last ? Math.Clamp(input.Time - last, 0, 0.05) : 0;
        _lastTime = input.Time;
        _scene.Update(input, dt);
        return _scene;
    }

    /// <summary>Draws the scene into <paramref name="canvas"/> (device pixels, transparent background).</summary>
    public void Render(SKCanvas canvas, SceneInput input, Scene3D scene, float alpha = 1)
    {
        var viewport = new Vector2(input.Width, input.Height);
        var frame = scene.Camera.Frame(viewport.Y * 0.95f);
        _list.Reset();
        scene.Build(input, _list, frame);
        LensParams? lens = null;
        if (scene.UsesLens)
        {
            var centerY = viewport.Y * (0.5f + (float)(input.FocusY - 0.5) * 0.5f);
            lens = new LensParams(viewport.X / 2, centerY, viewport.X * 0.47f, viewport.Y * 0.45f);
        }
        var hl = scene.HighlightOf(input);
        _renderer.Render(canvas, _list, frame, viewport.X, viewport.Y, input.FocusY, input.Theme.Font, lens, new Vector3(hl.X, hl.Y, hl.Z), alpha);
    }
}
