import Testing
import Foundation
import CoreLocation
import SwiftUI
@testable import Loop

struct CityPackTests {
    @Test func allCitiesDecodeAndPathsParseInsideBox() {
        let pack = CityPack.shared
        #expect(pack.cities.count == 40)
        for c in pack.cities {
            let p = SVGPath.parse(c.path)
            #expect(!p.isEmpty, "\(c.key)")
            let b = p.boundingRect
            #expect(b.minX >= 0 && b.maxX <= 200 && b.minY >= -2 && b.maxY <= 60, "\(c.key) \(b)")
        }
    }

    @Test func matching() {
        let pack = CityPack.shared
        #expect(pack.match(.init(latitude: 25.08, longitude: 55.14))?.key == "dxb")
        #expect(pack.match(.init(latitude: 24.50, longitude: 54.40))?.key == "auh")
        #expect(pack.match(.init(latitude: 51.50, longitude: -0.12))?.key == "lon")
        #expect(pack.match(.init(latitude: 25.0, longitude: 60.0)) == nil)
        #expect(pack.match(.init(latitude: 24.86, longitude: 54.84)) == nil)
    }

    @Test func nearestWinsAndBoundaryIsInside() {
        func city(_ k: String, _ lat: Double, _ lon: Double, _ r: Double) -> PackCity {
            PackCity(key: k, name: k, local: k, fontScale: 10, country: "", lat: lat, lon: lon, radiusKm: r, landmark: "", path: "")
        }
        let pack = CityPack(version: 1, box: [200, 60], ground: 58,
                            cities: [city("a", 0, 0, 500), city("b", 0, 1, 500)])
        #expect(pack.match(.init(latitude: 0, longitude: 0.8))?.key == "b")
        #expect(pack.match(.init(latitude: 0, longitude: 0.2))?.key == "a")
        let edge = CLLocationCoordinate2D(latitude: 0, longitude: -2)
        let d = CityPack.haversineKm(edge, .init(latitude: 0, longitude: 0))
        let exact = CityPack(version: 1, box: [200, 60], ground: 58, cities: [city("a", 0, 0, d)])
        #expect(exact.match(edge)?.key == "a")
    }

    @Test func parserIsSafeOnBadInput() {
        #expect(SVGPath.parse("").isEmpty)
        #expect(SVGPath.parse("L 5 5").isEmpty)
        #expect(SVGPath.parse("M1 2X3 4").boundingRect.width == 0)
        _ = SVGPath.parse("M1 2L3")
        _ = SVGPath.parse("M.5.5H-1V96.6862Q1 2 3 4C1 2 3 4 5 6Z")
        let p = SVGPath.parse("M0 58H93V36Z")
        #expect(p.boundingRect == CGRect(x: 0, y: 36, width: 93, height: 22))
    }

    @Test func sublineUsesNameOrCountry() {
        let pack = CityPack.shared
        #expect(pack.cities.first { $0.key == "dxb" }?.subline == "DUBAI · 25.20° N 55.27° E")
        #expect(pack.cities.first { $0.key == "lon" }?.subline == "UNITED KINGDOM · 51.51° N 0.13° W")
    }

    @Test func bundledCopyMatchesDesignSource() throws {
        // Only meaningful when the repo is on disk (simulator runs).
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../design/citypack.json").standardized
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let bundled = try #require(Bundle.main.url(forResource: "citypack", withExtension: "json"))
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: src))
    }

    @Test func cardDataPackCity() {
        let w = replayWorkout()
        #expect(CardData(workout: w).packCity?.key == "dxb")
        let empty = Workout(kind: .run, startDate: .now, endDate: .now, movingSeconds: 0, distanceMeters: 0)
        #expect(CardData(workout: empty).packCity == nil)
        #expect(CardData(workout: synthetic(lat: 25.0, lon: 60.0)).packCity == nil)
    }
}

/// A synthetic ~5 km loop around a centre, with a short walk stretch.
func synthetic(lat: Double, lon: Double, kind: ActivityKind = .run) -> Workout {
    let base = Date(timeIntervalSince1970: 1_793_000_000)
    var pts: [RoutePoint] = []
    var cum = 0.0
    let n = 240
    for i in 0...n {
        let t = Double(i) / Double(n) * 2 * .pi
        let r = 0.006 * (1 + 0.25 * sin(3 * t))
        let la = lat + r * sin(t), lo = lon + r * 1.4 * cos(t) + 0.004 * sin(2 * t)
        if let prev = pts.last {
            cum += CLLocation(latitude: prev.lat, longitude: prev.lon).distance(from: CLLocation(latitude: la, longitude: lo))
        }
        pts.append(RoutePoint(lat: la, lon: lo, alt: 5, t: base.addingTimeInterval(Double(i) * 7), speed: 3, hAcc: 5, cumMeters: cum, paused: nil))
    }
    let end = pts.last!.t
    let segs = [
        MoveSegment(kind: .run, startMeters: 0, endMeters: cum * 0.6, startTime: base, endTime: base.addingTimeInterval(1000)),
        MoveSegment(kind: .walk, startMeters: cum * 0.6, endMeters: cum * 0.7, startTime: base.addingTimeInterval(1000), endTime: base.addingTimeInterval(1200)),
        MoveSegment(kind: .run, startMeters: cum * 0.7, endMeters: cum, startTime: base.addingTimeInterval(1200), endTime: end),
    ]
    return Workout(kind: kind, startDate: base, endDate: end, movingSeconds: end.timeIntervalSince(base),
                   distanceMeters: cum, name: "Loop", steps: 5000, route: pts, segments: segs)
}

@MainActor
struct CityCardRenderTests {
    @Test func landmarkCardsRender() {
        let dir = ProcessInfo.processInfo.environment["LOOP_CITY_SHOTS"]
        if let dir { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        func write(_ img: UIImage?, _ name: String) {
            #expect(img?.cgImage?.width == 1080, "\(name)")
            #expect(img?.cgImage?.height == 1920, "\(name)")
            if let dir, let png = img?.pngData() { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
        }
        for c in CityPack.shared.cities {
            let w = synthetic(lat: c.lat, lon: c.lon, kind: c.key == "ams" ? .ride : .run)
            let d = CardData(workout: w)
            #expect(d.packCity?.key == c.key)
            write(CardRenderer.render(.city, data: d, hide: true, snap: nil), "city-\(c.key).png")
            if ["dxb", "auh", "tyo", "hyd", "lon"].contains(c.key) {
                write(CardRenderer.render(.city, data: d, hide: true, snap: nil, cityTone: .light), "city-\(c.key)-light.png")
            }
        }
        let fb = CardData(workout: synthetic(lat: 25.0, lon: 60.0))
        #expect(fb.packCity == nil)
        write(CardRenderer.render(.city, data: fb, hide: true, snap: nil), "city-fallback.png")
        // 0 / 1 point routes
        let empty = Workout(kind: .run, startDate: .now, endDate: .now, movingSeconds: 0, distanceMeters: 0)
        var e = CardData(workout: empty); e.packCity = CityPack.shared.cities.first
        write(CardRenderer.render(.city, data: e, hide: false, snap: nil), "city-empty.png")
    }
}
