import AppKit
import MapKit
import SwiftUI

// MARK: - Landmark atlas

struct Landmark: Hashable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    /// Lowercased tokens or phrases that send the tour here.
    let keywords: [String]

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The built-in landmark atlas: a San Francisco walk (the default tour) plus iconic places lyrics name.
enum AppleMapProvider {
    private static func lm(_ id: String, _ name: String, _ lat: Double, _ lon: Double, _ keys: [String] = []) -> Landmark {
        Landmark(id: id, name: name, latitude: lat, longitude: lon, keywords: keys)
    }

    /// In walking order; the tour loops through it when a line names no other place.
    static let sanFrancisco: [Landmark] = [
        lm("ggb", "Golden Gate Bridge", 37.8199, -122.4783, ["golden gate", "golden", "san francisco", "frisco"]),
        lm("pfa", "Palace of Fine Arts", 37.8029, -122.4484, ["palace"]),
        lm("lombard", "Lombard Street", 37.8021, -122.4187, ["lombard", "crooked"]),
        lm("coit", "Coit Tower", 37.8024, -122.4058, ["tower"]),
        lm("pier39", "Pier 39", 37.8087, -122.4098, ["pier", "harbor", "harbour"]),
        lm("ferry", "Ferry Building", 37.7955, -122.3937, ["ferry", "boat"]),
        lm("chinatown", "Chinatown", 37.7908, -122.4058, ["chinatown"]),
        lm("union", "Union Square", 37.7880, -122.4075, ["union", "square", "shopping"]),
        lm("alamo", "Alamo Square", 37.7764, -122.4346, ["alamo", "painted"]),
        lm("haight", "Haight-Ashbury", 37.7692, -122.4481, ["haight", "hippie"]),
        lm("ggp", "Golden Gate Park", 37.7694, -122.4862, ["park"]),
        lm("twin", "Twin Peaks", 37.7544, -122.4477, ["peaks", "hill", "hills"]),
        lm("dolores", "Mission Dolores Park", 37.7596, -122.4269, ["mission", "dolores"]),
        lm("oracle", "Oracle Park", 37.7786, -122.3893, ["baseball", "stadium", "giants"]),
        lm("applepark", "Apple Park", 37.3349, -122.0090, ["apple", "cupertino", "spaceship"]),
    ]

    static let world: [Landmark] = [
        lm("times", "Times Square", 40.7580, -73.9855, ["times square", "new york", "nyc", "broadway", "city never sleeps", "manhattan"]),
        lm("brooklyn", "Brooklyn Bridge", 40.7061, -73.9969, ["brooklyn"]),
        lm("central", "Central Park", 40.7812, -73.9665, ["central park"]),
        lm("liberty", "Statue of Liberty", 40.6892, -74.0445, ["liberty", "freedom"]),
        lm("empire", "Empire State Building", 40.7484, -73.9857, ["empire"]),
        lm("hollywood", "Hollywood Sign", 34.1341, -118.3215, ["hollywood", "los angeles", "la", "california", "fame"]),
        lm("santamonica", "Santa Monica Pier", 34.0083, -118.4988, ["santa monica", "beach", "boardwalk"]),
        lm("vegas", "Las Vegas Strip", 36.1147, -115.1728, ["vegas", "casino", "jackpot"]),
        lm("canyon", "Grand Canyon", 36.1069, -112.1129, ["canyon", "desert"]),
        lm("redrocks", "Red Rocks Amphitheatre", 39.6654, -105.2057, ["red rocks", "amphitheatre", "colorado", "concert"]),
        lm("pch", "Pacific Coast Highway", 36.3715, -121.9020, ["highway", "coast", "pacific", "road trip"]),
        lm("yosemite", "Yosemite Valley", 37.7456, -119.5936, ["yosemite", "valley", "mountain", "mountains", "waterfall"]),
        lm("needle", "Space Needle", 47.6205, -122.3493, ["seattle", "needle"]),
        lm("chicago", "Millennium Park", 41.8826, -87.6226, ["chicago", "windy"]),
        lm("nola", "French Quarter", 29.9584, -90.0644, ["new orleans", "jazz", "bourbon"]),
        lm("miami", "Miami Beach", 25.7907, -80.1300, ["miami", "florida"]),
        lm("nashville", "Lower Broadway", 36.1612, -86.7775, ["nashville", "tennessee", "honky"]),
        lm("shibuya", "Shibuya Crossing", 35.6595, 139.7005, ["shibuya", "tokyo", "japan"]),
        lm("tokyotower", "Tokyo Tower", 35.6586, 139.7454, ["tokyo tower"]),
        lm("eiffel", "Eiffel Tower", 48.8584, 2.2945, ["paris", "eiffel", "france"]),
        lm("louvre", "The Louvre", 48.8606, 2.3376, ["louvre", "mona"]),
        lm("bigben", "Big Ben", 51.5007, -0.1246, ["london", "big ben", "england"]),
        lm("abbey", "Abbey Road", 51.5320, -0.1779, ["abbey road"]),
        lm("towerbridge", "Tower Bridge", 51.5055, -0.0754, ["thames"]),
        lm("colosseum", "Colosseum", 41.8902, 12.4922, ["rome", "colosseum", "italy"]),
        lm("sagrada", "Sagrada Família", 41.4036, 2.1744, ["barcelona", "spain"]),
        lm("brandenburg", "Brandenburg Gate", 52.5163, 13.3777, ["berlin", "germany"]),
        lm("opera", "Sydney Opera House", -33.8568, 151.2153, ["sydney", "australia", "opera"]),
        lm("copacabana", "Copacabana", -22.9711, -43.1822, ["copacabana", "rio", "brazil"]),
        lm("burj", "Burj Khalifa", 25.1972, 55.2744, ["dubai", "burj"]),
        lm("taj", "Taj Mahal", 27.1751, 78.0421, ["taj", "agra"]),
        lm("gateway", "Gateway of India", 18.9220, 72.8347, ["mumbai", "bombay", "bollywood"]),
        lm("marina", "Marina Bay Sands", 1.2834, 103.8607, ["singapore"]),
        lm("hongkong", "Victoria Harbour", 22.2934, 114.1712, ["hong kong"]),
        lm("gangnam", "Gangnam", 37.4979, 127.0276, ["seoul", "gangnam", "korea"]),
        lm("niagara", "Niagara Falls", 43.0962, -79.0377, ["niagara", "falls"]),
        lm("cntower", "CN Tower", 43.6426, -79.3871, ["toronto", "canada"]),
        lm("oia", "Oia, Santorini", 36.4618, 25.3753, ["santorini", "greece", "island"]),
        lm("tromso", "Tromsø", 69.6492, 18.9553, ["northern lights", "aurora", "norway"]),
    ]

    static let all: [Landmark] = sanFrancisco + world

    /// The landmark a lyric line names, if any. A landmark's own name (its first keyword) beats a looser
    /// association ("Brooklyn" wins over "the city never sleeps"); then longer phrases win.
    static func match(_ line: String) -> Landmark? {
        let lower = line.lowercased()
        let tokens = Set(lower.split { !$0.isLetter }.map(String.init))
        var best: (Landmark, Int)?
        for l in all {
            for (i, k) in l.keywords.enumerated() {
                let hit = k.contains(" ") ? lower.contains(k) : tokens.contains(k)
                let score = k.count + (i == 0 ? 100 : 0)
                if hit, best == nil || score > best!.1 { best = (l, score) }
            }
        }
        return best?.0
    }

    /// Metres between two coordinates.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Initial bearing a → b in degrees.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180, dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// A point `meters` from `c` along `bearing` degrees.
    static func offset(_ c: CLLocationCoordinate2D, meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let b = bearing * .pi / 180
        let dLat = meters * cos(b) / 111_320
        let dLon = meters * sin(b) / (111_320 * cos(c.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
}

// MARK: - Snapshots

/// One dark-mode map picture request.
struct MapShot: Hashable {
    let latitude: Double
    let longitude: Double
    let distance: Double
    let pitch: Double
    let heading: Double
    let width: Int
    let height: Int

    init(center: CLLocationCoordinate2D, distance: Double, pitch: Double = 0, heading: Double = 0, size: CGSize) {
        // Rounded so nearly identical requests share a picture.
        latitude = (center.latitude * 10_000).rounded() / 10_000
        longitude = (center.longitude * 10_000).rounded() / 10_000
        self.distance = (distance / 25).rounded() * 25
        self.pitch = pitch.rounded()
        self.heading = heading.rounded()
        width = max(16, Int((size.width / 8).rounded()) * 8)
        height = max(16, Int((size.height / 8).rounded()) * 8)
    }

    var center: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var size: CGSize { CGSize(width: width, height: height) }
}

/// A rendered snapshot plus its projection.
struct MapPicture {
    let image: NSImage
    let shot: MapShot
    let project: (CLLocationCoordinate2D) -> CGPoint
}

/// Pre-renders `MKMapSnapshotter` pictures on demand and keeps a small cache. Main thread only; scenes
/// ask every frame, and get nil (draw the procedural map) until the picture arrives.
@MainActor
final class MapSnapshotCache {
    static let shared = MapSnapshotCache()

    private var pictures: [MapShot: MapPicture] = [:]
    private var order: [MapShot] = []
    private var pending: [MapShot: MKMapSnapshotter] = [:]
    private var failed: [MapShot: Date] = [:]
    private let limit = 28

    func picture(_ shot: MapShot) -> MapPicture? {
        if let p = pictures[shot] { return p }
        request(shot)
        return nil
    }

    func request(_ shot: MapShot) {
        guard pictures[shot] == nil, pending[shot] == nil, pending.count < 4 else { return }
        if let when = failed[shot], Date().timeIntervalSince(when) < 30 { return }
        let options = MKMapSnapshotter.Options()
        options.camera = MKMapCamera(lookingAtCenter: shot.center, fromDistance: shot.distance, pitch: CGFloat(shot.pitch), heading: shot.heading)
        options.size = shot.size
        options.mapType = .standard
        options.appearance = NSAppearance(named: .darkAqua)
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = shot.pitch > 0
        let snapshotter = MKMapSnapshotter(options: options)
        pending[shot] = snapshotter
        snapshotter.start { [weak self] snapshot, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending[shot] = nil
                guard let snapshot else { self.failed[shot] = Date(); return }
                self.store(MapPicture(image: snapshot.image, shot: shot, project: Self.projection(snapshot, shot: shot)), for: shot)
            }
        }
    }

    private func store(_ picture: MapPicture, for shot: MapShot) {
        pictures[shot] = picture
        order.append(shot)
        while order.count > limit { pictures[order.removeFirst()] = nil }
    }

    /// `Snapshot.point(for:)` in top-left-origin image points. The convention is detected: the camera's
    /// heading always points to the top of the picture, so a point ahead of the center must have a smaller y.
    private static func projection(_ s: MKMapSnapshotter.Snapshot, shot: MapShot) -> (CLLocationCoordinate2D) -> CGPoint {
        let center = s.point(for: shot.center)
        let ahead = s.point(for: AppleMapProvider.offset(shot.center, meters: shot.distance * 0.1, bearing: shot.heading))
        let flip = ahead.y > center.y
        let h = CGFloat(shot.height)
        return { coordinate in
            let p = s.point(for: coordinate)
            return CGPoint(x: p.x, y: flip ? h - p.y : p.y)
        }
    }

    /// Spins the run loop until the requested pictures arrive (still renders only).
    func prewarm(_ shots: [MapShot], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, shots.contains(where: { pictures[$0] == nil && failed[$0] == nil }) {
            shots.forEach(request)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

// MARK: - Projection fallback and drawing

/// Projects coordinates for a shot without a picture (equirectangular around the camera center), so
/// routes and pins land in the same place before and after the real map arrives.
enum MapMath {
    static func approximateProjection(_ shot: MapShot) -> (CLLocationCoordinate2D) -> CGPoint {
        let size = shot.size
        // Visible span ≈ camera distance at the default field of view.
        let metersPerPoint = shot.distance * 1.15 / max(1, Double(size.height))
        let heading = shot.heading * .pi / 180
        let cosLat = cos(shot.latitude * .pi / 180)
        return { c in
            let east = (c.longitude - shot.longitude) * 111_320 * cosLat
            let north = (c.latitude - shot.latitude) * 111_320
            let x = east * cos(heading) - north * sin(heading)
            let y = east * sin(heading) + north * cos(heading)
            return CGPoint(x: Double(size.width) / 2 + x / metersPerPoint, y: Double(size.height) / 2 - y / metersPerPoint)
        }
    }

    /// A dark procedural street map, drawn while (or instead of) the real snapshot loading.
    static func drawPlaceholder(in ctx: GraphicsContext, rect: CGRect, seed: Int) {
        ctx.fill(Path(rect), with: .color(Color(hex: "#1B1D21")))
        let park = CGRect(x: rect.minX + rect.width * CGFloat(Motion.hash(seed, 1) * 0.6), y: rect.minY + rect.height * CGFloat(Motion.hash(seed, 2) * 0.6),
                          width: rect.width * 0.28, height: rect.height * 0.22)
        ctx.fill(Path(roundedRect: park, cornerRadius: 6), with: .color(Color(hex: "#1E3326")))
        let water = CGRect(x: rect.maxX - rect.width * 0.22, y: rect.minY, width: rect.width * 0.22, height: rect.height)
        ctx.fill(Path(water), with: .color(Color(hex: "#16243A")))
        let step = max(18, rect.width / 14)
        var streets = Path()
        var x = rect.minX + step * CGFloat(Motion.hash(seed, 3))
        while x < rect.maxX { streets.move(to: CGPoint(x: x, y: rect.minY)); streets.addLine(to: CGPoint(x: x + rect.height * 0.08, y: rect.maxY)); x += step }
        var y = rect.minY + step * CGFloat(Motion.hash(seed, 4))
        while y < rect.maxY { streets.move(to: CGPoint(x: rect.minX, y: y)); streets.addLine(to: CGPoint(x: rect.maxX, y: y - rect.width * 0.04)); y += step }
        ctx.stroke(streets, with: .color(Color(hex: "#2C3038")), lineWidth: 1.2)
        var avenue = Path()
        avenue.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.18))
        avenue.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.2),
                        control1: CGPoint(x: rect.midX - rect.width * 0.1, y: rect.midY + rect.height * 0.3),
                        control2: CGPoint(x: rect.midX + rect.width * 0.1, y: rect.midY - rect.height * 0.35))
        ctx.stroke(avenue, with: .color(Color(hex: "#3A3F49")), lineWidth: 3.5)
    }

    /// Apple Maps route: dark casing under a bright blue line.
    static func drawRoute(_ points: [CGPoint], in ctx: GraphicsContext, width: CGFloat, color: Color = AppleColors.blue, upTo fraction: Double = 1) {
        guard points.count > 1 else { return }
        var path = Path()
        path.addLines(points)
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        ctx.stroke(path, with: .color(Color(hex: "#0B2A5C")), style: StrokeStyle(lineWidth: width + 3, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: .color(color.opacity(0.45)), style: style)
        if fraction > 0 {
            var g = ctx
            g.addFilter(.shadow(color: color.opacity(0.9), radius: 3.0))
            g.stroke(path.trimmedPath(from: 0, to: fraction), with: .color(color), style: style)
        }
    }

    /// A map pin: colored head with a white dot, a short stem and a soft glow.
    static func drawPin(at p: CGPoint, color: Color, in ctx: GraphicsContext, scale: CGFloat = 1, drop: Double = 1) {
        let s = scale * CGFloat(max(0.01, drop))
        let lift = CGFloat(1 - min(1, drop)) * 26 * scale
        let head = CGPoint(x: p.x, y: p.y - 16 * s - lift)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5 * scale, y: p.y - 2 * scale, width: 10 * scale, height: 4 * scale)), with: .color(.black.opacity(0.35)))
        var stem = Path()
        stem.move(to: CGPoint(x: head.x, y: head.y + 6 * s))
        stem.addLine(to: CGPoint(x: p.x, y: p.y - lift))
        ctx.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 2.5 * s, lineCap: .round))
        var g = ctx
        g.addFilter(.shadow(color: color.opacity(0.8), radius: 6))
        let r = 9 * s
        g.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)), with: .color(color))
        ctx.stroke(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.9)), lineWidth: 1.5 * s)
        let d = 3 * s
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - d, y: head.y - d, width: d * 2, height: d * 2)), with: .color(.white))
    }

    /// The pulsing blue "you are here" dot.
    /// - Parameter kick: beat impulse (0…1): the halo flashes outward and the dot swells on every hit.
    static func drawLocationDot(at p: CGPoint, in ctx: GraphicsContext, clock: Double, scale: CGFloat = 1, kick: CGFloat = 0) {
        let pulse = (clock * 0.9).truncatingRemainder(dividingBy: 1)
        let halo = (10 + 18 * CGFloat(pulse)) * scale
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                 with: .color(AppleColors.blue.opacity(0.35 * (1 - pulse))))
        if kick > 0.05 {
            let beatHalo = (12 + 16 * kick) * scale
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - beatHalo, y: p.y - beatHalo, width: beatHalo * 2, height: beatHalo * 2)),
                     with: .color(AppleColors.blue.opacity(0.45 * Double(kick))))
        }
        let ring = 9 * scale * (1 + 0.18 * kick)
        var g = ctx
        g.addFilter(.shadow(color: .black.opacity(0.4), radius: 3))
        g.fill(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)), with: .color(.white))
        let core = 6.5 * scale * (1 + 0.18 * kick)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)), with: .color(AppleColors.blue))
    }

    /// Point at `fraction` of a polyline's length.
    static func point(along pts: [CGPoint], fraction: Double) -> CGPoint {
        guard pts.count > 1 else { return pts.first ?? .zero }
        var lengths: [CGFloat] = [0]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + pts[i - 1].distance(pts[i])) }
        let target = lengths.last! * CGFloat(Motion.clamp01(fraction))
        for i in 1..<pts.count where lengths[i] >= target {
            let seg = max(0.0001, lengths[i] - lengths[i - 1])
            return pts[i - 1].lerp(pts[i], Double((target - lengths[i - 1]) / seg))
        }
        return pts.last!
    }
}
