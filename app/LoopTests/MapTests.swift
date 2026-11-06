import XCTest
@testable import Loop

final class MapTests: XCTestCase {
    // Vectors from server/src/geohash.ts encode().
    func testGeohashMatchesServer() {
        let v: [(Double, Double, String)] = [
            (25.2048, 55.2708, "thrr3squw"), (51.5074, -0.1278, "gcpvj0duq"),
            (-33.8688, 151.2093, "r3gx2f77b"), (-22.9068, -43.1729, "75cm9tfqn"), (25.157, 55.198, "thrr059yn"),
        ]
        for (lat, lon, g) in v {
            XCTAssertEqual(Geohash.encode(lat: lat, lon: lon, precision: 9), g)
            XCTAssertEqual(Geohash.encode(lat: lat, lon: lon, precision: 7), String(g.prefix(7)))
        }
    }

    func testBoundsAndCenterRoundTrip() {
        for (lat, lon) in [(25.2048, 55.2708), (-33.8688, 151.2093), (51.5074, -0.1278)] {
            for p in 5...7 {
                let g = Geohash.encode(lat: lat, lon: lon, precision: p)
                let b = Geohash.bounds(g)!
                XCTAssertTrue(b.s <= lat && lat < b.n && b.w <= lon && lon < b.e)
                let c = Geohash.center(g)!
                XCTAssertEqual(Geohash.encode(lat: c.lat, lon: c.lon, precision: p), g)
            }
        }
        XCTAssertNil(Geohash.bounds("abc")) // 'a' is not in the alphabet
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A straight line of points every 10 m, heading north-east from (lat0, lon0).
    private func line(_ meters: Double, lat0: Double = 25.10, lon0: Double = 55.20, east: Double = 0.6) -> [RoutePoint] {
        stride(from: 0.0, through: meters, by: 10).map { m in
            RoutePoint(lat: lat0 + m * 0.8 / 111_195, lon: lon0 + m * east / (111_195 * cos(lat0 * .pi / 180)),
                       alt: 0, t: t0.addingTimeInterval(m / 3), speed: 3, hAcc: 5, cumMeters: m, paused: nil)
        }
    }

    private func counts(_ routes: [[RoutePoint]]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: PersonalHeat.counts(routes).map { ($0.g, $0.n) })
    }

    func testSharedStreetCountsTwo() {
        let a = line(1000)
        // Same street for the first 1000 m, then it carries on further.
        let b = line(2000)
        let c = counts([a, b])
        let shared = PersonalHeat.cells(a)
        XCTAssertFalse(shared.isEmpty)
        for g in shared { XCTAssertEqual(c[g], 2, g) }
        let onlyB = PersonalHeat.cells(b).subtracting(shared)
        XCTAssertFalse(onlyB.isEmpty)
        for g in onlyB { XCTAssertEqual(c[g], 1, g) }
        XCTAssertTrue(PersonalHeat.cells(a).allSatisfy { $0.count == 7 })
    }

    func testOneWorkoutCountsOncePerCell() {
        let there = line(1000)
        let back = Array(there.reversed())
        XCTAssertTrue(counts([there + back]).values.allSatisfy { $0 == 1 })
    }

    func testPausedPointsAreIgnored() {
        var r = line(2000)
        for i in r.indices where r[i].cumMeters > 900 && r[i].cumMeters < 1100 { r[i].paused = true }
        let mid = r.first { $0.cumMeters >= 1000 }!
        XCTAssertFalse(PersonalHeat.cells(r).contains(Geohash.encode(lat: mid.lat, lon: mid.lon, precision: 7)))
        let all = r.map { RoutePoint(lat: $0.lat, lon: $0.lon, alt: 0, t: $0.t, speed: 3, hAcc: 5, cumMeters: $0.cumMeters, paused: true) }
        XCTAssertTrue(PersonalHeat.cells(all).isEmpty)
    }

    func testEmptyAndSinglePointRoutesGiveNothing() {
        XCTAssertTrue(PersonalHeat.cells([]).isEmpty)
        XCTAssertTrue(PersonalHeat.cells(Array(line(0))).isEmpty)
        XCTAssertTrue(PersonalHeat.counts([[], line(0)]).isEmpty)
    }

    func testSparsePointsAreDensified() {
        let dense = line(3000)
        let sparse = dense.enumerated().filter { $0.offset % 30 == 0 }.map(\.element) // every 300 m
        let a = PersonalHeat.cells(dense), b = PersonalHeat.cells(sparse)
        XCTAssertGreaterThanOrEqual(Double(a.intersection(b).count), Double(a.count) * 0.9)
    }

    func testGlowIsFaintForOneVisitAndCapped() {
        XCTAssertLessThan(HomeMapBackground.opacity(1), 0.1)
        XCTAssertGreaterThan(HomeMapBackground.opacity(4), HomeMapBackground.opacity(2))
        XCTAssertLessThanOrEqual(HomeMapBackground.opacity(1000), 0.7)
    }
}
