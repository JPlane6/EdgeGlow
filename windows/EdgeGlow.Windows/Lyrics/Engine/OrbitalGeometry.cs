using System;

namespace EdgeGlow.Lyrics;

/// <summary>Polar spoke-and-ring web geometry (a 1:1 port of the macOS OrbitalGeometry).</summary>
public readonly struct OrbitalGeometry
{
    public int Spokes { get; init; }
    public int Rings { get; init; }
    public double InnerRadius { get; init; }
    public double RingStep { get; init; }

    public OrbitalGeometry(int spokes = 8, int rings = 4, double innerRadius = 150, double ringStep = 150)
    {
        Spokes = spokes; Rings = rings; InnerRadius = innerRadius; RingStep = ringStep;
    }

    public double OuterRadius => InnerRadius + RingStep * (Rings - 1);
    public double Radius(int ring) => InnerRadius + RingStep * ring;
    public double Angle(int spoke) => 2 * Math.PI * spoke / Spokes;

    /// <summary>Word i owns a fixed slot (spoke, ring): it walks around the spokes, one ring outward per revolution.</summary>
    public (int Spoke, int Ring) Slot(int index) => (index % Spokes, (index / Spokes) % Rings);

    public (double X, double Z) Point(int spoke, int ring, double rotation)
    {
        var a = Angle(spoke) + rotation;
        var r = Radius(ring);
        return (Math.Cos(a) * r, Math.Sin(a) * r);
    }

    /// <summary>Rotation that brings <paramref name="spoke"/> to face the viewer (+z, angle pi/2).</summary>
    public double RotationFacing(int spoke) => Math.PI / 2 - Angle(spoke);
}
