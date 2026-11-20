import CoreLocation
import SwiftUI

/// A walking route between two places, with right-angle-ish bends like a city grid.
struct Road {
    let points: [CLLocationCoordinate2D]
    let bends: Int

    static func walk(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, seed: Int) -> Road {
        let bends = 1 + Int(Motion.hash(seed, 3) * 3)
        var pts = [a]
        for k in 0..<bends {
            let t = Double(k + 1) / Double(bends + 1)
            let jitter = Motion.signedHash(seed, k) * 0.12
            let prev = pts[pts.count - 1]
            if k % 2 == 0 {
                pts.append(CLLocationCoordinate2D(latitude: prev.latitude, longitude: a.longitude + (b.longitude - a.longitude) * (t + jitter)))
            } else {
                pts.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * (t + jitter), longitude: prev.longitude))
            }
        }
        let last = pts[pts.count - 1]
        pts.append(bends % 2 == 1 ? CLLocationCoordinate2D(latitude: b.latitude, longitude: last.longitude)
                                  : CLLocationCoordinate2D(latitude: last.latitude, longitude: b.longitude))
        pts.append(b)
        return Road(points: pts, bends: bends)
    }

    var meters: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + AppleMapProvider.distance($1.0, $1.1) }
    }
}

/// One lyric line of the tour: walk from `from` to `to`, then drop a pin.
struct MapLeg {
    let line: Int
    let from: Landmark
    let to: Landmark
    let road: Road
    let pin: Color
    /// Full-screen map (the line named a place) instead of the floating window.
    let enlarged: Bool
    let in3D: Bool
    let turnSymbol: String
    let shot: (CGSize) -> MapShot
}

/// Builds the tour for a song: each line walks to the next San Francisco stop, or jumps to the place it
/// names (arriving on a short walk into it).
enum AppleMapPlan {
    static let cache = PlanCache<[MapLeg]>()
    static let pinColors = ["#FF375F", "#BF5AF2", "#40C8E0", "#FFD6E0"].map(Color.init(hex:))

    static func build(_ lyrics: TimedLyrics) -> [MapLeg] {
        var legs: [MapLeg] = []
        var here = AppleMapProvider.sanFrancisco[0]
        var sfIndex = 0
        for gi in lyrics.groups.indices {
            let text = lyrics.lineText(gi)
            let named = AppleMapProvider.match(text)
            let to: Landmark
            let enlarged: Bool
            var from = here
            if let named, named != here {
                to = named
                enlarged = true
            } else {
                // Next walking stop; Apple Park is far, so it is only reached when a lyric names it.
                repeat { sfIndex = (sfIndex + 1) % AppleMapProvider.sanFrancisco.count }
                while AppleMapProvider.sanFrancisco[sfIndex].id == "applepark" || AppleMapProvider.sanFrancisco[sfIndex] == here
                to = AppleMapProvider.sanFrancisco[sfIndex]
                enlarged = false
            }
            // Far jumps arrive on a short walk into the destination.
            if AppleMapProvider.distance(from.coordinate, to.coordinate) > 6_000 {
                let start = AppleMapProvider.offset(to.coordinate, meters: 900 + Motion.hash(gi, 8) * 700, bearing: Motion.hash(gi, 9) * 360)
                from = Landmark(id: to.id + "-approach", name: to.name, latitude: start.latitude, longitude: start.longitude, keywords: [])
            }
            let road = Road.walk(from: from.coordinate, to: to.coordinate, seed: gi)
            let in3D = enlarged || gi % 3 == 1
            let turn = turnSymbol(road, text: text, last: gi == lyrics.groups.count - 1)
            let bbox = bounds(road.points)
            let span = max(AppleMapProvider.distance(bbox.0, bbox.1), 400)
            let center = CLLocationCoordinate2D(latitude: (bbox.0.latitude + bbox.1.latitude) / 2, longitude: (bbox.0.longitude + bbox.1.longitude) / 2)
            let heading = in3D ? AppleMapProvider.bearing(from.coordinate, to.coordinate) : 0
            let distance = min(9_000, max(700, span * (in3D ? 1.6 : 2.2)))
            legs.append(MapLeg(line: gi, from: from, to: to, road: road, pin: pinColors[gi % pinColors.count], enlarged: enlarged,
                               in3D: in3D, turnSymbol: turn,
                               shot: { size in MapShot(center: center, distance: distance, pitch: in3D ? 55 : 0, heading: heading, size: size) }))
            here = to
        }
        return legs
    }

    private static func bounds(_ pts: [CLLocationCoordinate2D]) -> (CLLocationCoordinate2D, CLLocationCoordinate2D) {
        let lats = pts.map(\.latitude), lons = pts.map(\.longitude)
        return (CLLocationCoordinate2D(latitude: lats.min()!, longitude: lons.min()!), CLLocationCoordinate2D(latitude: lats.max()!, longitude: lons.max()!))
    }

    private static func turnSymbol(_ road: Road, text: String, last: Bool) -> String {
        if last { return "mappin.and.ellipse" }
        let p = road.points
        guard p.count >= 3 else { return "arrow.turn.up.right" }
        let a = p[p.count - 3], b = p[p.count - 2], c = p[p.count - 1]
        let cross = (b.longitude - a.longitude) * (c.latitude - b.latitude) - (b.latitude - a.latitude) * (c.longitude - b.longitude)
        if text.hasSuffix("?") { return cross > 0 ? "arrow.uturn.left" : "arrow.uturn.right" }
        return cross > 0 ? "arrow.turn.up.left" : "arrow.turn.up.right"
    }
}

/// Measurement formatting for the turn banner.
enum MapDistance {
    static func format(_ meters: Double) -> String {
        if Locale.current.measurementSystem == .metric {
            return meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int((meters / 10).rounded()) * 10) m"
        }
        let feet = meters * 3.28084
        return feet >= 1000 ? String(format: "%.1f mi", meters / 1609.34) : "\(Int((feet / 10).rounded()) * 10) ft"
    }
}
