import Foundation

/// The user's own heat map: how many different workouts passed through each p7 cell.
/// Pure and on-device only; nothing here leaves the phone.
enum PersonalHeat {
    static let precision = 7
    /// Points farther apart than this are joined with in-between points, so no cell is skipped.
    static let maxGap = 50.0
    static let step = 25.0

    struct Cell: Equatable, Sendable { var g: String; var n: Int }

    /// Distinct cells one route passes through. Paused points are ignored and break the line.
    static func cells(_ route: [RoutePoint]) -> Set<String> {
        guard route.filter({ $0.paused != true }).count >= 2 else { return [] }
        var out = Set<String>()
        var prev: RoutePoint?
        for p in route {
            guard p.paused != true else { prev = nil; continue }
            if let a = prev {
                let d = meters(a.lat, a.lon, p.lat, p.lon)
                if d > maxGap {
                    let n = Int((d / step).rounded(.up))
                    for i in 1..<n {
                        let f = Double(i) / Double(n)
                        out.insert(Geohash.encode(lat: a.lat + (p.lat - a.lat) * f, lon: a.lon + (p.lon - a.lon) * f,
                                                  precision: precision))
                    }
                }
            }
            out.insert(Geohash.encode(lat: p.lat, lon: p.lon, precision: precision))
            prev = p
        }
        return out
    }

    /// Cells with the number of different workouts that passed through them.
    static func counts(_ routes: [[RoutePoint]]) -> [Cell] {
        var c: [String: Int] = [:]
        for r in routes { for g in cells(r) { c[g, default: 0] += 1 } }
        return c.map { Cell(g: $0.key, n: $0.value) }.sorted { $0.n < $1.n }
    }

    static func meters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_000 * asin(min(1, sqrt(h)))
    }
}
