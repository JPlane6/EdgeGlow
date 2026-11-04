import Foundation

/// Polar spoke-and-ring web geometry (Foundation only, no AppKit), shared with the Windows port.
/// Word `i` of the song owns a fixed slot `(spoke, ring)`, so the web never re-lays-out while it turns.
struct OrbitalGeometry {
    var spokes = 8
    var rings = 4
    var innerRadius = 150.0
    var ringStep = 150.0

    var outerRadius: Double { innerRadius + ringStep * Double(rings - 1) }
    func radius(ring: Int) -> Double { innerRadius + ringStep * Double(ring) }
    func angle(spoke: Int) -> Double { 2 * .pi * Double(spoke) / Double(spokes) }

    /// Slot of word `index`: it walks around the spokes, stepping one ring outward per revolution.
    func slot(_ index: Int) -> (spoke: Int, ring: Int) {
        (index % spokes, (index / spokes) % rings)
    }

    /// Disc-plane position (x, z) for a slot after the disc has turned by `rotation` radians.
    func point(spoke: Int, ring: Int, rotation: Double) -> (x: Double, z: Double) {
        let a = angle(spoke: spoke) + rotation
        let r = radius(ring: ring)
        return (cos(a) * r, sin(a) * r)
    }

    /// Rotation that brings `spoke` to face the viewer (+z, i.e. angle π/2).
    func rotationFacing(spoke: Int) -> Double { .pi / 2 - angle(spoke: spoke) }
}
