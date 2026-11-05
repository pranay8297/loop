import Foundation
import CoreLocation

struct Split: Sendable, Equatable {
    var index: Int          // 1-based km
    var meters: Double      // 1000 for full splits
    var seconds: Double
    var isFull: Bool { meters >= 999.5 }
    var pace: Double { seconds / (meters / 1000) }
}

enum SplitsCalculator {
    /// Per-km splits over moving time. The last element may be a partial split.
    static func splits(_ points: [RoutePoint]) -> [Split] {
        guard points.count > 1 else { return [] }
        // cumulative moving time per point
        var moving: [Double] = [0]
        for i in 1..<points.count {
            let dt = points[i].isPaused ? 0 : max(0, points[i].t.timeIntervalSince(points[i - 1].t))
            moving.append(moving[i - 1] + dt)
        }
        let total = points.last!.cumMeters
        guard total > 0 else { return [] }
        func timeAt(_ m: Double) -> Double {
            // first index with cum >= m
            var lo = 0, hi = points.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if points[mid].cumMeters < m { lo = mid + 1 } else { hi = mid } }
            if lo == 0 { return moving[0] }
            let a = points[lo - 1], b = points[lo]
            let span = b.cumMeters - a.cumMeters
            let f = span > 0 ? (m - a.cumMeters) / span : 1
            return moving[lo - 1] + (moving[lo] - moving[lo - 1]) * f
        }
        var out: [Split] = []
        var k = 1
        var prevT = 0.0
        while Double(k) * 1000 <= total + 1e-6 {
            let t = timeAt(Double(k) * 1000)
            out.append(Split(index: k, meters: 1000, seconds: t - prevT))
            prevT = t; k += 1
        }
        let rest = total - Double(k - 1) * 1000
        if rest >= 10 {
            out.append(Split(index: k, meters: rest, seconds: moving.last! - prevT))
        }
        return out
    }

    static func fastestFullIndex(_ splits: [Split]) -> Int? {
        splits.filter(\.isFull).min(by: { $0.seconds < $1.seconds })?.index
    }
    static func fastestKmSeconds(_ points: [RoutePoint]) -> Double? {
        splits(points).filter(\.isFull).map(\.seconds).min()
    }
}

enum RouteTrimmer {
    static func trim(_ points: [RoutePoint], meters: Double = 200) -> [RoutePoint] {
        guard let last = points.last, last.cumMeters >= meters * 2 else { return [] }
        return points.filter { $0.cumMeters >= meters && $0.cumMeters <= last.cumMeters - meters }
    }
}

/// What a past workout contributes to highlight checks.
struct WorkoutDigest: Sendable {
    var kind: ActivityKind
    var distanceMeters: Double
    var fastestKm: Double?
    var hadWalk: Bool
    var isCheckIn: Bool
}

enum Highlight: Equatable, Sendable {
    case firstOfKind(ActivityKind)
    case first5KNoWalk
    case longest(ActivityKind, meters: Double)
    case fastestKm(seconds: Double)
    case ranFraction(Double)

    var text: String {
        switch self {
        case .firstOfKind(let k): "First \(k.noun)"
        case .first5KNoWalk: "First 5K without a walk break"
        case .longest(let k, let m): "Longest \(k.noun) yet, " + String(format: "%.1f km", m / 1000)
        case .fastestKm(let s): "Fastest km yet, " + Format.pace(s)
        case .ranFraction(let f): "Ran \(Int((f * 100).rounded()))% of it"
        }
    }
    /// Used as a name override.
    var namePhrase: String? {
        switch self {
        case .firstOfKind(let k): "First \(k.noun)"
        case .first5KNoWalk: "First 5K without a walk break"
        case .longest(let k, let m): "Longest \(k.noun) yet, " + String(format: "%.1f km", m / 1000)
        case .fastestKm: "Fastest km yet"
        case .ranFraction: nil
        }
    }
}

enum Highlights {
    static func compute(current: WorkoutDigest, runFraction: Double?, history: [WorkoutDigest]) -> [Highlight] {
        var out: [Highlight] = []
        let same = history.filter { $0.kind == current.kind && !$0.isCheckIn }
        if same.isEmpty { out.append(.firstOfKind(current.kind)) }
        if current.kind == .run, current.distanceMeters >= 5000, !current.hadWalk,
           !same.contains(where: { $0.distanceMeters >= 5000 && !$0.hadWalk }) {
            out.append(.first5KNoWalk)
        }
        if same.count >= 2, current.distanceMeters > (same.map(\.distanceMeters).max() ?? 0) {
            out.append(.longest(current.kind, meters: current.distanceMeters))
        }
        if current.kind == .run, same.count >= 2, let f = current.fastestKm {
            let best = same.compactMap(\.fastestKm).min()
            if best == nil || f < best! { out.append(.fastestKm(seconds: f)) }
        }
        if current.kind == .run, let rf = runFraction, current.hadWalk {
            out.append(.ranFraction(rf))
        }
        return out
    }
}

enum RouteShape: Sendable { case loop, outAndBack, pointToPoint }

enum RouteGeometry {
    static func distance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
    }

    static func shape(_ pts: [RoutePoint]) -> RouteShape {
        guard pts.count >= 4, let first = pts.first, let last = pts.last else { return .pointToPoint }
        let total = last.cumMeters
        if total > 200 {
            // Out-and-back: points of the second half lie within ~60 m of the first half.
            let half = pts.filter { $0.cumMeters <= total / 2 }
            let back = pts.filter { $0.cumMeters > total / 2 }
            let stride = max(1, half.count / 200)
            let sampled = Swift.stride(from: 0, to: half.count, by: stride).map { half[$0] }
            let bStride = max(1, back.count / 100)
            var near = 0, checked = 0
            for i in Swift.stride(from: 0, to: back.count, by: bStride) {
                checked += 1
                if sampled.contains(where: { distance($0, back[i]) <= 60 }) { near += 1 }
            }
            if checked > 0, Double(near) / Double(checked) >= 0.7 { return .outAndBack }
        }
        if distance(first, last) <= 300 { return .loop }
        return .pointToPoint
    }

    static func midpoint(_ pts: [RoutePoint]) -> RoutePoint? {
        guard let last = pts.last else { return nil }
        return pts.first(where: { $0.cumMeters >= last.cumMeters / 2 }) ?? last
    }

    static func farthestFromStart(_ pts: [RoutePoint]) -> RoutePoint? {
        guard let first = pts.first else { return nil }
        return pts.max(by: { distance(first, $0) < distance(first, $1) })
    }
}
