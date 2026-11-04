using System;
using System.Collections.Generic;
using System.Numerics;

namespace EdgeGlow.Lyrics;

public enum DrawKind { Text, Ribbon, Glow, Plume, Icon, Flare, Panel }

/// <summary>Which pass an item is drawn in: back (alpha backdrops), body (depth-sorted words), glow (additive light), top.</summary>
public enum DrawLayer { Back, Body, Glow, Top }

/// <summary>Shadow styles for a word: how the quad is drawn under the lit text.</summary>
public enum TextStyle { Fill, Outline, Shadow }

public struct DrawItem
{
    public DrawKind Kind;
    public DrawLayer Layer;
    /// <summary>Quad corners: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left (text, icon, panel) or the sprite centre in [0].</summary>
    public Vector3 C0, C1, C2, C3;
    public Vector3 End;               // ribbon end point
    public Vector4 Color;
    public float Size;                // ribbon width / sprite radius in world units
    public float Blur;                // depth-of-field blur amount (legacy "blur units")
    public float ShadowPx;            // screen-pixel blur radius for glyph shadows
    public float Extra;               // plume strength, glow falloff, panel border strength
    public float Stretch;             // plume aspect, panel aspect
    public float Corner;              // panel corner radius (fraction of height)
    public float Depth;
    public string? Text;
    public bool Mono;
    public TextStyle Style;
}

/// <summary>Everything a scene wants on screen this frame. The renderer sorts and rasterizes it.</summary>
public sealed class DrawList
{
    public List<DrawItem> Items { get; } = new();
    public void Reset() => Items.Clear();

    public static float NearFade(float depth)
    {
        var t = Math.Clamp((depth - 140) / 300, 0f, 1f);
        return t * t * (3 - 2 * t);
    }

    public void Text(string text, bool mono, Vector3 center, Vector3 right, Vector3 up, Vector4 color,
                     in CameraFrame cam, float blur = 0, float shadowPx = 0, TextStyle style = TextStyle.Fill, DrawLayer layer = DrawLayer.Body, DrawKind kind = DrawKind.Text)
    {
        var item = new DrawItem
        {
            Kind = kind, Layer = layer, Text = text, Mono = mono, Style = style, Color = color, Blur = blur, ShadowPx = shadowPx,
            C0 = center - right + up, C1 = center + right + up, C2 = center + right - up, C3 = center - right - up,
        };
        item.Depth = cam.DepthOf(center);
        item.Color.W *= NearFade(item.Depth);
        Items.Add(item);
    }

    public void Panel(Vector3 center, Vector3 right, Vector3 up, Vector4 color, float corner, float border, float aspect, DrawLayer layer, in CameraFrame cam)
    {
        var item = new DrawItem
        {
            Kind = DrawKind.Panel, Layer = layer, Color = color, Corner = corner, Extra = border, Stretch = aspect,
            C0 = center - right + up, C1 = center + right + up, C2 = center + right - up, C3 = center - right - up,
        };
        item.Depth = cam.DepthOf(center);
        item.Color.W *= NearFade(item.Depth);
        Items.Add(item);
    }

    public void Ribbon(Vector3 a, Vector3 b, float width, Vector4 color, float glow, DrawLayer layer, in CameraFrame cam)
    {
        var item = new DrawItem { Kind = DrawKind.Ribbon, Layer = layer, C0 = a, End = b, Size = width, Color = color, Extra = glow };
        item.Depth = cam.DepthOf((a + b) * 0.5f);
        item.Color.W *= NearFade(item.Depth);
        Items.Add(item);
    }

    public void Sprite(DrawKind kind, Vector3 p, float radius, Vector4 color, float extra, float stretch, DrawLayer layer, in CameraFrame cam)
    {
        var item = new DrawItem { Kind = kind, Layer = layer, C0 = p, Size = radius, Color = color, Extra = extra, Stretch = stretch };
        item.Depth = cam.DepthOf(p);
        item.Color.W *= NearFade(item.Depth);
        Items.Add(item);
    }
}
