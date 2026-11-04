using System;
using System.Numerics;

namespace EdgeGlow.Lyrics;

/// <summary>Smooth 1D gradient noise used for camera shake (band-limited, so shake feels like a handheld camera).</summary>
public static class Perlin
{
    private static double Hash(long i, long seed)
    {
        var x = unchecked((ulong)(i * 374761393L + seed * 668265263L));
        x = unchecked((x ^ (x >> 13)) * 1274126177UL);
        x ^= x >> 16;
        return (x % 20_000UL) / 10_000.0 - 1;
    }

    public static double Noise(double t, int seed)
    {
        var i = (long)Math.Floor(t);
        var f = t - i;
        var u = f * f * f * (f * (f * 6 - 15) + 10);
        var g0 = Hash(i, seed) * f;
        var g1 = Hash(i + 1, seed) * (f - 1);
        return (g0 + (g1 - g0) * u) * 2;
    }
}

/// <summary>Spring-damper (stiffness 170, damping 20 by default), integrated in 1/240 s sub-steps.</summary>
public struct Spring3
{
    public Vector3d Value, Velocity;
    public Spring3(Vector3d v) { Value = v; Velocity = default; }

    public void Step(Vector3d target, double dt, double stiffness = 170, double damping = 20)
    {
        var remaining = dt;
        while (remaining > 0)
        {
            var h = Math.Min(remaining, 1.0 / 240);
            Velocity += (stiffness * (target - Value) - damping * Velocity) * h;
            Value += Velocity * h;
            remaining -= h;
        }
    }
}

public struct Spring1
{
    public double Value, Velocity;
    public Spring1(double v) { Value = v; Velocity = 0; }

    public void Step(double target, double dt, double stiffness = 170, double damping = 20)
    {
        var remaining = dt;
        while (remaining > 0)
        {
            var h = Math.Min(remaining, 1.0 / 240);
            Velocity += (stiffness * (target - Value) - damping * Velocity) * h;
            Value += Velocity * h;
            remaining -= h;
        }
    }
}

/// <summary>Double-precision 3-vector for the camera springs (System.Numerics has no Vector3d).</summary>
public struct Vector3d
{
    public double X, Y, Z;
    public Vector3d(double x, double y, double z) { X = x; Y = y; Z = z; }
    public static Vector3d From(Vector3 v) => new(v.X, v.Y, v.Z);
    public Vector3 ToF() => new((float)X, (float)Y, (float)Z);
    public static Vector3d operator +(Vector3d a, Vector3d b) => new(a.X + b.X, a.Y + b.Y, a.Z + b.Z);
    public static Vector3d operator -(Vector3d a, Vector3d b) => new(a.X - b.X, a.Y - b.Y, a.Z - b.Z);
    public static Vector3d operator *(Vector3d a, double s) => new(a.X * s, a.Y * s, a.Z * s);
    public static Vector3d operator *(double s, Vector3d a) => a * s;
    public double Length => Math.Sqrt(X * X + Y * Y + Z * Z);
    public static double Dot(Vector3d a, Vector3d b) => a.X * b.X + a.Y * b.Y + a.Z * b.Z;
    public static Vector3d Cross(Vector3d a, Vector3d b) => new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X);
    public Vector3d Normalized() { var l = Length; return l < 1e-12 ? new Vector3d(0, 0, 1) : this * (1 / l); }
}

/// <summary>Camera basis for one frame (right-handed: +x right, +y up, +z away from the viewer).</summary>
public struct CameraFrame
{
    public Vector3 Position;
    public Vector3 Right, Up, Forward;
    public float FocusDistance;
    /// <summary>Focal length in pixels: perspective scale at distance z is focal / z.</summary>
    public float Focal;

    public float DepthOf(Vector3 p) => Vector3.Dot(p - Position, Forward);

    /// <summary>Depth-of-field: blur amount (0..1) and the matching fade for things off the focal plane.</summary>
    public (float Blur, float Fade) Dof(float depth, float range = 900)
    {
        var d = Math.Min(Math.Abs(depth - FocusDistance) / range, 1);
        return (d, 1 - 0.55f * d * d);
    }
}

/// <summary>
/// The shared cinematic rig: spring-damper tracking of a focus target with look-ahead (stiffness 170,
/// damping 20), banking, trauma-squared Perlin shake, and impulse springs for dolly, pitch, yaw and roll.
/// </summary>
public sealed class CinematicCamera3D
{
    private Spring3 _position, _lookAt;
    private Spring1 _bank, _dolly, _pitchKick, _yawKick, _rollKick;
    private bool _primed;
    private double _trauma, _shakeTime;
    private readonly int _seed;

    public CinematicCamera3D(int seed = 7) { _seed = seed; }

    public void Reset()
    {
        _position = default; _lookAt = default;
        _bank = default; _dolly = default; _pitchKick = default; _yawKick = default; _rollKick = default;
        _trauma = 0; _primed = false;
    }

    public void AddTrauma(double amount) => _trauma = Math.Min(1, _trauma + amount);

    /// <summary>One-shot kicks that spring back (dolly, pitch/yaw/roll in radians).</summary>
    public void Kick(double dolly = 0, double pitch = 0, double yaw = 0, double roll = 0)
    {
        _dolly.Velocity += dolly * 14; _pitchKick.Velocity += pitch * 14;
        _yawKick.Velocity += yaw * 14; _rollKick.Velocity += roll * 14;
    }

    public void Snap(Vector3d position, Vector3d lookAt)
    {
        _position = new Spring3(position); _lookAt = new Spring3(lookAt);
        _primed = true;
    }

    public void Update(double dt, Vector3d desiredPosition, Vector3d target, Vector3d lookAhead,
                       double anticipation, double bank, double bass, double vocalSpike)
    {
        var look = target + (lookAhead - target) * anticipation;
        if (!_primed) Snap(desiredPosition, look);
        _position.Step(desiredPosition, dt);
        _lookAt.Step(look, dt);
        _bank.Step(bank, dt, 60, 11);
        _dolly.Step(0, dt, 90, 11); _pitchKick.Step(0, dt, 90, 11);
        _yawKick.Step(0, dt, 90, 11); _rollKick.Step(0, dt, 90, 11);
        _trauma = Math.Max(0, _trauma - dt * 0.9);
        if (bass > 0.82) _trauma = Math.Max(_trauma, 0.12 + 0.18 * (bass - 0.82) / 0.18);
        if (vocalSpike > 0.85) _trauma = Math.Max(_trauma, 0.1);
        _shakeTime += dt;
    }

    private static Vector3d Rotate(Vector3d v, Vector3d axis, double angle)
    {
        double c = Math.Cos(angle), s = Math.Sin(angle);
        return v * c + Vector3d.Cross(axis, v) * s + axis * (Vector3d.Dot(axis, v) * (1 - c));
    }

    public CameraFrame Frame(float fovFocal)
    {
        var shake = _trauma * _trauma;
        var t = _shakeTime * 9;
        double nx = Perlin.Noise(t, _seed), ny = Perlin.Noise(t + 31.7, _seed + 1);
        double nr = Perlin.Noise(t + 77.1, _seed + 2), np = Perlin.Noise(t + 120.3, _seed + 3), nyaw = Perlin.Noise(t + 200.9, _seed + 4);

        var pos = _position.Value;
        var toLook = _lookAt.Value - pos;
        var fwd = toLook.Normalized();
        var distance = toLook.Length;
        pos -= fwd * (_dolly.Value * 60);

        var worldUp = new Vector3d(0, 1, 0);
        var right = Vector3d.Cross(worldUp, fwd).Normalized();
        var up = Vector3d.Cross(fwd, right);
        var roll = _bank.Value + _rollKick.Value + shake * 0.06 * nr;
        var pitch = _pitchKick.Value + shake * 0.045 * np;
        var yaw = _yawKick.Value + shake * 0.045 * nyaw;
        fwd = Rotate(fwd, up, yaw); right = Rotate(right, up, yaw);
        fwd = Rotate(fwd, right, -pitch); up = Rotate(up, right, -pitch);
        right = Rotate(right, fwd, roll); up = Rotate(up, fwd, roll);
        pos += right * (shake * 26 * nx) + up * (shake * 26 * ny);

        return new CameraFrame
        {
            Position = pos.ToF(), Right = right.ToF(), Up = up.ToF(), Forward = fwd.ToF(),
            FocusDistance = (float)Math.Max(distance, 200), Focal = fovFocal,
        };
    }
}
