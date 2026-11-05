import Testing
import Foundation
@testable import Loop

private struct RNG {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    mutating func gauss() -> Double {
        let u = max(next(), 1e-12), v = next()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}

/// AR(1)-correlated GPS wobble in meters (east, north).
private struct Wobble {
    var sigma: Double
    var e = 0.0, n = 0.0
    let rho = 0.9
    mutating func step(_ r: inout RNG) -> (Double, Double) {
        let k = sqrt(1 - rho * rho) * sigma
        e = rho * e + k * r.gauss(); n = rho * n + k * r.gauss()
        return (e, n)
    }
}

/// Simulates a workout at 1 Hz and runs it through a DistanceFilter.
private struct Sim {
    static let lat0 = 25.1972, lon0 = 55.2744 // Dubai
    var filter: DistanceFilter
    var rng: RNG
    var t: Date
    var x = 0.0, y = 0.0 // true position, meters east/north
    var total = 0.0
    var steps = 0
    var stepFrac = 0.0
    var pedoDist = 0.0
    var rejected = 0

    init(kind: ActivityKind, seed: UInt64 = 42) {
        t = Date(timeIntervalSince1970: 1_793_000_000)
        filter = DistanceFilter(kind: kind, start: t)
        rng = RNG(state: seed)
    }

    func fix(dx: Double, dy: Double, hAcc: Double, speed: Double, at time: Date, stationary: Bool? = false) -> LocationFix {
        let lat = Sim.lat0 + dy / 111_320
        let lon = Sim.lon0 + dx / (111_320 * cos(Sim.lat0 * .pi / 180))
        return LocationFix(lat: lat, lon: lon, altitude: 0, speed: speed, hAcc: hAcc, timestamp: time, isStationary: stationary)
    }

    @discardableResult
    mutating func feed(_ f: LocationFix) -> DistanceFilter.Decision {
        let d = filter.fix(f)
        switch d {
        case .reject: rejected += 1
        case .accept(let inc): total += inc
        }
        return d
    }

    /// Runs `seconds` of movement. `v` m/s along x; `stepsPerMin` 0 means standing.
    mutating func run(seconds: Int, v: Double, wobble: inout Wobble, hAcc: ClosedRange<Double>,
                      stepsPerMin: Double, metersPerStep: Double?, doppler: Double? = nil,
                      pedoUntil: Int = .max, dx: Double = 1) {
        for i in 0..<seconds {
            t = t.addingTimeInterval(1)
            x += v * dx
            if stepsPerMin > 0, i < pedoUntil {
                stepFrac += stepsPerMin / 60
                let whole = Int(stepFrac); stepFrac -= Double(whole)
                steps += whole
                if let m = metersPerStep { pedoDist += Double(whole) * m }
                if i % 3 == 2 {
                    filter.pedometer(PedometerSample(time: t, steps: steps, cadence: stepsPerMin,
                                                     distance: metersPerStep == nil ? nil : pedoDist))
                }
            } else if i % 3 == 2, i < pedoUntil, steps > 0 || stepsPerMin == 0 {
                filter.pedometer(PedometerSample(time: t, steps: steps, cadence: 0,
                                                 distance: metersPerStep == nil ? nil : pedoDist))
            }
            let (we, wn) = wobble.step(&rng)
            let h = rng.uniform(hAcc.lowerBound, hAcc.upperBound)
            feed(fix(dx: x + we, dy: y + wn, hAcc: h, speed: doppler ?? (v > 0 ? v : -1), at: t))
        }
    }
}

struct DistanceFilterTests {
    @Test func standingStill() {
        var s = Sim(kind: .walk)
        s.steps = 10
        s.filter.pedometer(PedometerSample(time: s.t, steps: 10, cadence: 0, distance: 6))
        var w = Wobble(sigma: 6.5)
        s.run(seconds: 180, v: 0, wobble: &w, hAcc: 8...20, stepsPerMin: 0, metersPerStep: 0.6)
        print("standingStill total", s.total)
        #expect(s.total < 15)
    }

    @Test func stairsIndoors() {
        var s = Sim(kind: .walk)
        var w = Wobble(sigma: 8)
        s.run(seconds: 180, v: 0, wobble: &w, hAcc: 15...30, stepsPerMin: 60, metersPerStep: 0.6)
        print("stairsIndoors total", s.total, "pedometer", s.pedoDist)
        #expect(abs(s.total - s.pedoDist) <= 0.15 * s.pedoDist)
        #expect(s.total < 150)
    }

    @Test func outdoorWalk() {
        var s = Sim(kind: .walk)
        var w = Wobble(sigma: 2)
        s.run(seconds: Int(400 / 1.4), v: 1.4, wobble: &w, hAcc: 5...5, stepsPerMin: 110, metersPerStep: 0.75)
        print("outdoorWalk total", s.total, "true", s.x)
        #expect(abs(s.total - s.x) <= 0.05 * s.x)
    }

    @Test func userScenarioWalkThenStairs() {
        var s = Sim(kind: .walk)
        var w = Wobble(sigma: 2)
        s.run(seconds: Int(400 / 1.4), v: 1.4, wobble: &w, hAcc: 5...5, stepsPerMin: 110, metersPerStep: 0.75)
        var w2 = Wobble(sigma: 8)
        s.run(seconds: 120, v: 0, wobble: &w2, hAcc: 15...30, stepsPerMin: 60, metersPerStep: 0.6)
        print("userScenario total", s.total)
        #expect(s.total < 500)
    }

    @Test func staleFirstFixRejected() {
        var s = Sim(kind: .walk)
        let stale = s.fix(dx: 800, dy: 0, hAcc: 5, speed: -1, at: s.t.addingTimeInterval(-120))
        #expect(s.feed(stale) == .reject)
        var w = Wobble(sigma: 2)
        s.run(seconds: Int(200 / 1.4), v: 1.4, wobble: &w, hAcc: 5...5, stepsPerMin: 110, metersPerStep: 0.75)
        print("staleFirstFix total", s.total, "true", s.x)
        #expect(abs(s.total - s.x) <= 0.05 * s.x)
    }

    @Test func rideThenStop() {
        var s = Sim(kind: .ride)
        var w = Wobble(sigma: 2)
        s.run(seconds: 2000 / 6, v: 6, wobble: &w, hAcc: 5...5, stepsPerMin: 0, metersPerStep: nil)
        let moving = s.total
        var w2 = Wobble(sigma: 3)
        // stopped: Doppler reports a valid ~0 speed
        s.run(seconds: 60, v: 0, wobble: &w2, hAcc: 5...5, stepsPerMin: 0, metersPerStep: nil, doppler: 0)
        #expect(s.filter.fix(s.fix(dx: 0, dy: 0, hAcc: 5, speed: 0, at: s.t)) == .reject) // same timestamp
        print("ride moving", moving, "true", s.x, "stop adds", s.total - moving)
        #expect(abs(moving - s.x) <= 0.03 * s.x)
        #expect(s.total - moving < 15)
    }

    @Test func runWithSilentPedometer() {
        var s = Sim(kind: .run)
        var w = Wobble(sigma: 2)
        s.run(seconds: 1000 / 3, v: 3, wobble: &w, hAcc: 5...5, stepsPerMin: 170, metersPerStep: 1.0,
              doppler: 3, pedoUntil: 10)
        print("runSilentPedometer total", s.total, "true", s.x)
        #expect(abs(s.total - s.x) <= 0.05 * s.x)
    }

    @Test func implausibleJumpRejected() {
        var s = Sim(kind: .walk)
        var w = Wobble(sigma: 1)
        s.run(seconds: 30, v: 1.4, wobble: &w, hAcc: 5...5, stepsPerMin: 110, metersPerStep: nil)
        s.t = s.t.addingTimeInterval(1)
        let jump = s.fix(dx: s.x + 40, dy: 0, hAcc: 5, speed: 1.4, at: s.t)
        #expect(s.feed(jump) == .reject)
    }

    @Test func outOfOrderRejected() {
        var s = Sim(kind: .walk)
        var w = Wobble(sigma: 1)
        s.run(seconds: 5, v: 1.4, wobble: &w, hAcc: 5...5, stepsPerMin: 110, metersPerStep: nil)
        #expect(s.feed(s.fix(dx: s.x, dy: 0, hAcc: 5, speed: 1.4, at: s.t)) == .reject)
        #expect(s.feed(s.fix(dx: s.x, dy: 0, hAcc: 30, speed: 1.4, at: s.t.addingTimeInterval(1))) == .reject)
    }

    @Test func pausedDistanceNotCounted() {
        var s = Sim(kind: .walk)
        var w = Wobble(sigma: 2)
        s.run(seconds: 100, v: 1.4, wobble: &w, hAcc: 5...5, stepsPerMin: 110, metersPerStep: 0.75)
        let before = s.x
        s.filter.pause()
        s.run(seconds: 100, v: 1.4, wobble: &w, hAcc: 5...5, stepsPerMin: 110, metersPerStep: 0.75)
        let pausedMeters = s.x - before
        #expect(s.total < before * 1.05)
        s.filter.resume()
        // indoors after resume: step mode must not count the paused pedometer distance
        s.run(seconds: 100, v: 1.4, wobble: &w, hAcc: 15...20, stepsPerMin: 110, metersPerStep: 0.75)
        let expected = s.x - pausedMeters
        print("pauseResume total", s.total, "expected", expected)
        #expect(abs(s.total - expected) <= 0.1 * expected)
    }

    @Test func replayRouteMatchesStraightSum() throws {
        let url = try #require(Bundle.main.url(forResource: "ReplayRoute", withExtension: "json"))
        let raw = try JSONDecoder().decode([ReplayPoint].self, from: Data(contentsOf: url))
        let base = Date(timeIntervalSince1970: 1_793_000_000)
        var f = DistanceFilter(kind: .run, start: base)
        var total = 0.0, straight = 0.0, steps = 0.0, lastT = 0.0
        var prev: ReplayPoint?
        let sim = Sim(kind: .run)
        for p in raw {
            if let a = prev {
                straight += RouteGeometry.distance(
                    RoutePoint(lat: a.lat, lon: a.lon, alt: 0, t: base, speed: 0, hAcc: 5, cumMeters: 0, paused: nil),
                    RoutePoint(lat: p.lat, lon: p.lon, alt: 0, t: base, speed: 0, hAcc: 5, cumMeters: 0, paused: nil))
            }
            prev = p
            let due = base.addingTimeInterval(p.t)
            let cadence = p.speed >= 2.2 ? 166.0 : 112.0
            steps += cadence / 60 * (p.t - lastT); lastT = p.t
            if Int(p.t) % 3 == 0 { f.pedometer(PedometerSample(time: due, steps: Int(steps), cadence: cadence, distance: nil)) }
            var fx = sim.fix(dx: 0, dy: 0, hAcc: 5, speed: p.speed, at: due)
            fx.lat = p.lat; fx.lon = p.lon
            if case .accept(let inc) = f.fix(fx) { total += inc }
        }
        print("replay total", total, "straight", straight)
        #expect(abs(total - straight) <= 0.03 * straight)
    }

    /// From a real walk (5 Nov, Abu Dhabi): GPS reported ~14 m accuracy with a valid Doppler speed
    /// for 25 minutes, and step-based distance read 19% short. A Doppler-backed fix is trusted.
    @Test func cityStreetsWithDopplerTrustGPS() {
        var s = Sim(kind: .walk)
        var w = Wobble(sigma: 3)
        s.run(seconds: 1200, v: 1.3, wobble: &w, hAcc: 13.5...14.5, stepsPerMin: 70, metersPerStep: 0.75)
        print("cityStreets total", s.total, "true", s.x)
        #expect(abs(s.total - s.x) <= 0.06 * s.x)
    }

    /// Local only: replays a real recorded route if LOOP_REAL_ROUTE points at one. Real routes stay
    /// out of the repo (they show where someone lives); without the variable this test is skipped.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOP_REAL_ROUTE"] != nil))
    func realRouteMatchesDoppler() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOOP_REAL_ROUTE"]!)
        let pts = try JSONDecoder().decode([RoutePoint].self, from: Data(contentsOf: url))
        var f = DistanceFilter(kind: .walk, start: pts[0].t)
        var total = 0.0, doppler = 0.0
        for (i, p) in pts.enumerated() {
            if case .accept(let inc) = f.fix(LocationFix(lat: p.lat, lon: p.lon, altitude: p.alt, speed: p.speed,
                                                          hAcc: p.hAcc, timestamp: p.t, isStationary: nil)) { total += inc }
            if i > 0, p.speed >= 0 { doppler += p.speed * min(5, p.t.timeIntervalSince(pts[i - 1].t)) }
        }
        print("real route total", total, "doppler", doppler)
        #expect(abs(total - doppler) <= 0.05 * doppler)
    }
}
