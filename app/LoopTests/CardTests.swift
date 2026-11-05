import Testing
import Foundation
import CoreLocation
import UIKit
@testable import Loop

/// A run built from the bundled replay route, with a walk stretch from 2.6 to 3.0 km.
func replayWorkout(place: String? = "Kite Beach", city: String? = "Dubai") -> Workout {
    let url = Bundle.main.url(forResource: "ReplayRoute", withExtension: "json")!
    let raw = try! JSONDecoder().decode([ReplayPoint].self, from: Data(contentsOf: url))
    let base = Date(timeIntervalSince1970: 1_793_000_000)
    var pts: [RoutePoint] = []
    var cum = 0.0
    for (i, r) in raw.enumerated() {
        if i > 0 {
            let a = raw[i - 1]
            cum += CLLocation(latitude: a.lat, longitude: a.lon).distance(from: CLLocation(latitude: r.lat, longitude: r.lon))
        }
        pts.append(RoutePoint(lat: r.lat, lon: r.lon, alt: r.alt, t: base.addingTimeInterval(r.t), speed: r.speed, hAcc: 5, cumMeters: cum, paused: nil))
    }
    func time(at m: Double) -> Date { pts.first(where: { $0.cumMeters >= m })?.t ?? pts.last!.t }
    let total = cum
    let segs = [
        MoveSegment(kind: .run, startMeters: 0, endMeters: 2600, startTime: base, endTime: time(at: 2600)),
        MoveSegment(kind: .walk, startMeters: 2600, endMeters: 3000, startTime: time(at: 2600), endTime: time(at: 3000)),
        MoveSegment(kind: .run, startMeters: 3000, endMeters: total, startTime: time(at: 3000), endTime: pts.last!.t),
    ]
    let w = Workout(kind: .run, startDate: base, endDate: pts.last!.t, movingSeconds: pts.last!.t.timeIntervalSince(base),
                    distanceMeters: total, name: "Kite Beach sunrise loop", steps: 5400, route: pts, segments: segs)
    w.placeName = place
    w.cityName = city
    return w
}

struct ProjectionTests {
    @Test func pointsLandInsideRectAndAspectIsKept() {
        // 0.01° lat by 0.02° lon at 25° N
        let coords = [CLLocationCoordinate2D(latitude: 25, longitude: 55), .init(latitude: 25.01, longitude: 55.02),
                      .init(latitude: 25.005, longitude: 55.01)]
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)
        let pts = RouteProjection.project(coords, into: rect, padding: 8)
        for p in pts { #expect(rect.insetBy(dx: 7.99, dy: 7.99).contains(p)) }
        let w = pts.map(\.x).max()! - pts.map(\.x).min()!
        let h = pts.map(\.y).max()! - pts.map(\.y).min()!
        let expected = (0.02 * cos(25.005 * .pi / 180)) / 0.01
        #expect(abs(Double(w / h) - expected) < 0.001)
        // centred
        #expect(abs((pts.map(\.x).max()! + pts.map(\.x).min()!) / 2 - rect.midX) < 0.01)
        // north is up
        #expect(pts[1].y < pts[0].y)
    }

    @Test func singlePointAndEmpty() {
        #expect(RouteProjection.project([], into: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        let one = RouteProjection.project([.init(latitude: 1, longitude: 1)], into: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(one == [CGPoint(x: 5, y: 5)])
    }
}

struct CardTextTests {
    @Test func placeFallbackChain() {
        #expect(CardText.place(placeName: "Saadiyat", cityName: "Abu Dhabi", kind: .run) == "Saadiyat")
        #expect(CardText.place(placeName: nil, cityName: "Abu Dhabi", kind: .run) == "Abu Dhabi")
        #expect(CardText.place(placeName: "  ", cityName: nil, kind: .run) == "Your run")
        #expect(CardText.place(placeName: nil, cityName: nil, kind: .walk) == "Your walk")
        #expect(CardText.place(placeName: nil, cityName: nil, kind: .ride) == "Your ride")
        #expect(CardText.city(placeName: "Saadiyat", cityName: "Abu Dhabi") == "Abu Dhabi")
        #expect(CardText.city(placeName: "Dubai", cityName: "dubai") == nil)
        #expect(CardText.city(placeName: nil, cityName: "Dubai") == nil)
        #expect(CardText.coordinate(.init(latitude: 24.5412, longitude: 54.4321)) == "24.54° N 54.43° E")
    }

    @Test func walkAndRideNumbers() {
        let w = replayWorkout()
        let walk = Workout(kind: .walk, startDate: w.startDate, endDate: w.endDate, movingSeconds: 1800, distanceMeters: 3000)
        #expect(CardData(workout: walk).ranPercent == nil)
        #expect(!CardData(workout: walk).monoLine.contains("ran"))
        let ride = Workout(kind: .ride, startDate: w.startDate, endDate: w.endDate, movingSeconds: 3600, distanceMeters: 24000)
        let d = CardData(workout: ride)
        #expect(d.paceText == "24.0 km/h")
        #expect(d.ranPercent == nil)
        #expect(CardData(workout: w).ranPercent != nil)
    }
}

struct CardRouteTests {
    @Test func hiddenEndsExcludeFirstAndLast200m() {
        let w = replayWorkout()
        let total = w.route.last!.cumMeters
        let pieces = CardData(workout: w).pieces(hide: true)
        let kept = pieces.flatMap(\.coords)
        #expect(!kept.isEmpty)
        let start = w.route.filter { $0.cumMeters < 200 }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let end = w.route.filter { $0.cumMeters > total - 200 }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        // No kept point equals a point from the hidden ends.
        for c in kept {
            #expect(!start.contains(where: { $0.latitude == c.latitude && $0.longitude == c.longitude }))
            #expect(!end.contains(where: { $0.latitude == c.latitude && $0.longitude == c.longitude }))
        }
        let trimmed = CardRoute.points(w.route, hide: true)
        #expect(trimmed.allSatisfy { $0.cumMeters >= 200 && $0.cumMeters <= total - 200 })
        // Shown in full when hide is off.
        #expect(CardData(workout: w).pieces(hide: false).flatMap(\.coords).count >= w.route.count)
    }

    @Test func shortRouteHidesEverything() {
        let pts = route(meters: 350, speed: 3)
        let w = Workout(kind: .run, startDate: .now, endDate: .now, movingSeconds: 120, distanceMeters: 350, route: pts)
        #expect(CardData(workout: w).pieces(hide: true).isEmpty)
    }
}

@MainActor
struct CardRendererTests {
    @Test func everyStyleRendersAt1080x1920() async {
        let w = replayWorkout(place: "Saadiyat", city: "Abu Dhabi")
        let history = [DayEntry(date: w.startDate.addingTimeInterval(-86400 * 10), kind: .swim, meters: 1000),
                       DayEntry(date: w.startDate.addingTimeInterval(-86400 * 3), kind: .gym, meters: 0),
                       DayEntry(date: w.startDate, kind: .run, meters: w.distanceMeters)]
        let data = CardData(workout: w, history: history)
        let dir = ProcessInfo.processInfo.environment["LOOP_CARD_SHOTS"]
        for style in CardStyle.allCases {
            let snap = style == .city || style == .photo ? await CardRenderer.snapshot(for: data, style: style, timeout: 15) : nil
            let img = CardRenderer.render(style, data: data, hide: true, snap: snap)
            #expect(img?.cgImage?.width == 1080, "\(style)")
            #expect(img?.cgImage?.height == 1920, "\(style)")
            if let dir, let png = img?.pngData() {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("card-\(style.rawValue).png"))
            }
        }
    }

    @Test func longPlaceStillRenders() async {
        let w = replayWorkout(place: "Saadiyat Island Public Beach Promenade", city: "Abu Dhabi")
        let data = CardData(workout: w)
        let img = CardRenderer.render(.city, data: data, hide: true, snap: nil)
        #expect(img?.cgImage?.width == 1080)
        if let dir = ProcessInfo.processInfo.environment["LOOP_CARD_SHOTS"], let png = img?.pngData() {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("check-city-long.png"))
        }
    }

    @Test func rendersWithoutSnapshotOrPlace() {
        let w = replayWorkout(place: nil, city: nil)
        let data = CardData(workout: w)
        #expect(data.place == "Your run")
        for style in CardStyle.allCases {
            let img = CardRenderer.render(style, data: data, hide: true, snap: nil)
            #expect(img?.cgImage?.width == 1080)
            #expect(img?.cgImage?.height == 1920)
        }
    }
}
