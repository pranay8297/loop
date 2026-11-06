import Foundation

/// Standard base32 geohash, longitude bit first. Matches `server/src/geohash.ts`.
enum Geohash {
    static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    struct Box: Equatable { var s, w, n, e: Double }

    static func encode(lat: Double, lon: Double, precision: Int) -> String {
        var latMin = -90.0, latMax = 90.0, lonMin = -180.0, lonMax = 180.0
        var out = ""
        var bit = 0, ch = 0, even = true
        while out.count < precision {
            if even {
                let mid = (lonMin + lonMax) / 2
                if lon >= mid { ch = (ch << 1) | 1; lonMin = mid } else { ch <<= 1; lonMax = mid }
            } else {
                let mid = (latMin + latMax) / 2
                if lat >= mid { ch = (ch << 1) | 1; latMin = mid } else { ch <<= 1; latMax = mid }
            }
            even.toggle()
            bit += 1
            if bit == 5 { out.append(base32[ch]); bit = 0; ch = 0 }
        }
        return out
    }

    /// Bounds of a cell, or nil for an invalid hash.
    static func bounds(_ g: String) -> Box? {
        var latMin = -90.0, latMax = 90.0, lonMin = -180.0, lonMax = 180.0
        var even = true
        for c in g {
            guard let v = base32.firstIndex(of: c) else { return nil }
            for i in stride(from: 4, through: 0, by: -1) {
                let b = (v >> i) & 1
                if even {
                    let mid = (lonMin + lonMax) / 2
                    if b == 1 { lonMin = mid } else { lonMax = mid }
                } else {
                    let mid = (latMin + latMax) / 2
                    if b == 1 { latMin = mid } else { latMax = mid }
                }
                even.toggle()
            }
        }
        return g.isEmpty ? nil : Box(s: latMin, w: lonMin, n: latMax, e: lonMax)
    }

    static func center(_ g: String) -> (lat: Double, lon: Double)? {
        guard let b = bounds(g) else { return nil }
        return ((b.s + b.n) / 2, (b.w + b.e) / 2)
    }
}
