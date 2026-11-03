using System;
using System.Collections.Generic;
using SkiaSharp;

namespace EdgeGlow;

/// <summary>A rest point on the bezel, its inward unit normal, and its fractional string-node position.</summary>
internal readonly record struct OutlineSample(SKPoint Point, SKPoint Normal, double Node);

/// <summary>
/// The bezel at rest as line and arc segments, clockwise from top-center in y-down coordinates, so it can be
/// sampled by arc length (with inward normals) for the string nodes. (The macOS camera-housing notch has no
/// Windows equivalent, so the outline is always a rounded rectangle.)
/// </summary>
internal sealed class BezelOutline
{
    private sealed class Segment
    {
        public bool IsArc;
        public SKPoint A, B;           // line
        public SKPoint Center;         // arc
        public double Radius, Start, Sweep;

        public double Length => IsArc
            ? Radius * Math.Abs(Sweep)
            : Math.Sqrt((B.X - A.X) * (double)(B.X - A.X) + (B.Y - A.Y) * (double)(B.Y - A.Y));

        public (SKPoint Point, SKPoint Normal) Sample(double s)
        {
            if (!IsArc)
            {
                var length = Math.Max(Length, 1e-9);
                var dx = (B.X - A.X) / length;
                var dy = (B.Y - A.Y) / length;
                // Interior is on the right of the clockwise direction of travel.
                return (new SKPoint((float)(A.X + dx * s), (float)(A.Y + dy * s)), new SKPoint((float)-dy, (float)dx));
            }
            var a = Start + (Sweep >= 0 ? 1 : -1) * s / Radius;
            var dirX = Math.Cos(a);
            var dirY = Math.Sin(a);
            var point = new SKPoint((float)(Center.X + Radius * dirX), (float)(Center.Y + Radius * dirY));
            // Convex corners face the arc center.
            var sign = Sweep >= 0 ? -1.0 : 1.0;
            return (point, new SKPoint((float)(sign * dirX), (float)(sign * dirY)));
        }
    }

    private readonly List<Segment> _segments = new();
    public double Length { get; }

    public BezelOutline(float width, float height, float r)
    {
        const float minX = 0, minY = 0;
        var maxX = width;
        var maxY = height;
        var midX = width / 2;
        SKPoint P(float x, float y) => new(x, y);
        Segment Line(SKPoint a, SKPoint b) => new() { A = a, B = b };
        Segment Arc(SKPoint c, double start, double sweep) => new() { IsArc = true, Center = c, Radius = r, Start = start, Sweep = sweep };

        _segments.Add(Line(P(midX, minY), P(maxX - r, minY)));
        _segments.Add(Arc(P(maxX - r, minY + r), -Math.PI / 2, Math.PI / 2));
        _segments.Add(Line(P(maxX, minY + r), P(maxX, maxY - r)));
        _segments.Add(Arc(P(maxX - r, maxY - r), 0, Math.PI / 2));
        _segments.Add(Line(P(maxX - r, maxY), P(minX + r, maxY)));
        _segments.Add(Arc(P(minX + r, maxY - r), Math.PI / 2, Math.PI / 2));
        _segments.Add(Line(P(minX, maxY - r), P(minX, minY + r)));
        _segments.Add(Arc(P(minX + r, minY + r), Math.PI, Math.PI / 2));
        _segments.Add(Line(P(minX + r, minY), P(midX, minY)));

        double total = 0;
        foreach (var s in _segments) total += s.Length;
        Length = total;
    }

    /// <summary>Point and inward normal at arc length <paramref name="distance"/> from top-center.</summary>
    public (SKPoint Point, SKPoint Normal) Sample(double distance)
    {
        var s = Math.Max(distance, 0);
        foreach (var segment in _segments)
        {
            var length = segment.Length;
            if (s < length) return segment.Sample(s);
            s -= length;
        }
        var last = _segments[^1];
        return last.Sample(last.Length);
    }
}
