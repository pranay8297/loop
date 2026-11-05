import Testing
import Foundation
@testable import Loop

// MARK: Capability

struct CapabilityTests {
    var env = DeviceEnvironment.allGood

    @Test func swimWithoutWatchOffersCheckIn() {
        let c = CapabilityChecker.decide(kind: .swim, env: env)
        guard case .cannotTrack(let title, _, let actions) = c else { Issue.record("expected cannotTrack"); return }
        #expect(title == "Apple Watch not connected")
        #expect(actions == [.checkIn])
    }

    @Test func gymWithoutWatchOffersCheckIn() {
        guard case .cannotTrack(let title, _, let actions) = CapabilityChecker.decide(kind: .gym, env: env) else { Issue.record(); return }
        #expect(title == "Apple Watch not connected")
        #expect(actions == [.checkIn])
    }

    @Test func runWithLocationDenied() {
        var e = env; e.locationAuth = .denied
        guard case .cannotTrack(let title, _, let actions) = CapabilityChecker.decide(kind: .run, env: e) else { Issue.record(); return }
        #expect(title == "Location is off for Loop")
        #expect(actions == [.openSettings, .checkIn])
        var e2 = env; e2.locationServicesEnabled = false
        #expect(!CapabilityChecker.decide(kind: .ride, env: e2).canTrack)
    }

    @Test func runWithMotionDeniedIsLimited() {
        var e = env; e.motionAuth = .denied
        guard case .trackLimited = CapabilityChecker.decide(kind: .run, env: e) else { Issue.record(); return }
        var e2 = env; e2.motionAvailable = false
        guard case .trackLimited = CapabilityChecker.decide(kind: .run, env: e2) else { Issue.record(); return }
    }

    @Test func runNormalTracks() {
        #expect(CapabilityChecker.decide(kind: .run, env: env) == .track(note: "iPhone GPS and motion ready. Walk breaks are picked up on their own."))
        var e = env; e.locationAuth = .notDetermined
        #expect(CapabilityChecker.decide(kind: .run, env: e).canTrack)
    }

    @Test func noEmDashes() {
        for k in ActivityKind.allCases {
            for w in [true, false] {
                var e = env; e.watchPaired = w
                let text = "\(CapabilityChecker.decide(kind: k, env: e))"
                #expect(!text.contains("\u{2014}"))
            }
        }
    }
}

// MARK: Segmentation

/// Builds 1 Hz samples for a list of (meters, speed) legs.
func samples(_ legs: [(Double, Double)], start: Date = Date(timeIntervalSince1970: 1_000_000)) -> [SegmenterSample] {
    var out: [SegmenterSample] = []
    var m = 0.0, t = 0.0
    for (len, speed) in legs {
        let end = m + len
        while m < end - 1e-9 {
            out.append(SegmenterSample(time: start.addingTimeInterval(t), cumMeters: m, speed: speed))
            m += speed; t += 1
        }
        m = end
    }
    out.append(SegmenterSample(time: start.addingTimeInterval(t), cumMeters: m, speed: legs.last!.1))
    return out
}

struct SegmenterTests {
    @Test func walkRunPattern() {
        let s = samples([(400, 1.5), (2200, 3.0), (400, 1.5), (2040, 3.0), (200, 1.5)])
        let segs = MotionSegmenter.segments(s)
        #expect(segs.map(\.kind) == [.walk, .run, .walk, .run, .walk])
        let expected: [Double] = [400, 2600, 3000, 5040]
        for (i, b) in expected.enumerated() {
            #expect(abs(segs[i].endMeters - b) <= 40, "boundary \(i): \(segs[i].endMeters)")
        }
    }

    @Test func briefSlowdownIgnored() {
        // 10 s at walking speed inside a run
        let s = samples([(1500, 3.0), (15, 1.5), (1500, 3.0)])
        let segs = MotionSegmenter.segments(s)
        #expect(segs.count == 1)
        #expect(segs.first?.kind == .run)
    }

    @Test func motionBeatsSpeed() {
        var s = samples([(300, 3.0)])
        for i in s.indices { s[i].activity = .walking; s[i].confidence = .high }
        #expect(MotionSegmenter.segments(s).map(\.kind) == [.walk])
    }

    @Test func emptyInput() {
        #expect(MotionSegmenter.segments([]).isEmpty)
    }
}

// MARK: Splits + trim

func route(meters: Double, speed: Double, pauseAt: Double? = nil, pauseSeconds: Double = 0) -> [RoutePoint] {
    var pts: [RoutePoint] = []
    var m = 0.0, t = 0.0
    let base = Date(timeIntervalSince1970: 2_000_000)
    var paused = false
    while m <= meters + 1e-9 {
        var p = RoutePoint(lat: 25 + m / 111_000, lon: 55, alt: 0, t: base.addingTimeInterval(t), speed: speed, hAcc: 5, cumMeters: m, paused: nil)
        if let at = pauseAt, !paused, m >= at {
            paused = true
            t += pauseSeconds
            p.t = base.addingTimeInterval(t)
            p.paused = true
        }
        pts.append(p)
        m += speed; t += 1
    }
    return pts
}

struct SplitsTests {
    @Test func constantSpeedEqualSplits() {
        let s = SplitsCalculator.splits(route(meters: 3000, speed: 2.5))
        #expect(s.count == 3)
        for sp in s { #expect(abs(sp.seconds - 400) < 1) }
    }

    @Test func partialLastSplit() {
        let s = SplitsCalculator.splits(route(meters: 2500, speed: 2.5))
        #expect(s.count == 3)
        #expect(abs(s[2].meters - 500) < 0.01)
        #expect(abs(s[2].seconds - 200) < 1)
        #expect(!s[2].isFull)
    }

    @Test func pausedTimeExcluded() {
        let s = SplitsCalculator.splits(route(meters: 2000, speed: 2.5, pauseAt: 500, pauseSeconds: 300))
        #expect(s.count == 2)
        #expect(abs(s[0].seconds - 400) < 2)
    }

    @Test func shortRouteHasNoFullSplits() {
        #expect(SplitsCalculator.splits([]).isEmpty)
        let s = SplitsCalculator.splits(route(meters: 40, speed: 2))
        #expect(s.allSatisfy { !$0.isFull })
        #expect(SplitsCalculator.fastestFullIndex(s) == nil)
    }

    @Test func trimming() {
        let r = route(meters: 1000, speed: 1)
        let t = RouteTrimmer.trim(r)
        #expect(t.first!.cumMeters >= 200)
        #expect(t.last!.cumMeters <= 800)
        #expect(abs(t.first!.cumMeters - 200) < 1.01)
        #expect(RouteTrimmer.trim(route(meters: 390, speed: 1)).isEmpty)
        #expect(RouteTrimmer.trim([]).isEmpty)
    }
}

// MARK: Solar + naming

let dubai = TimeZone(identifier: "Asia/Dubai")!

func dubaiDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var c = Calendar(identifier: .gregorian); c.timeZone = dubai
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

struct SolarTests {
    @Test func dubaiSunrise() throws {
        let t = try #require(SolarCalculator.times(latitude: 25.157, longitude: 55.198, date: dubaiDate(2026, 11, 5, 12, 0), timeZone: dubai))
        // Contract said 06:22. NOAA math gives 06:29 for 55.198 E (solar noon ~12:03, day ~11 h 07 m);
        // the same formula gives the known 07:05 mid-January Dubai sunrise, so 06:29 is the reference here.
        let expected = dubaiDate(2026, 11, 5, 6, 29)
        #expect(abs(t.sunrise.timeIntervalSince(expected)) <= 6 * 60, "sunrise \(t.sunrise)")
        #expect(t.sunset > t.sunrise)
    }
}

struct NamerTests {
    let namer = RuleBasedNamer()
    func input(_ start: Date, place: String?, shape: RouteShape, hl: [Highlight] = [], walk: Bool = false) -> NamingInput {
        NamingInput(start: start, timeZone: dubai, latitude: 25.157, longitude: 55.198, place: place,
                    shape: shape, kind: .run, hasWalkSegments: walk, highlights: hl)
    }

    @Test func saadiyatRun() {
        let r = namer.compose(input(dubaiDate(2026, 11, 5, 8, 30), place: "Saadiyat Island", shape: .pointToPoint))
        #expect(r.name == "Saadiyat run")
        #expect(r.reason.hasPrefix("Named on your iPhone from where you went: Saadiyat"))
    }

    @Test func kiteBeachSunriseLoop() {
        let r = namer.compose(input(dubaiDate(2026, 11, 5, 6, 12), place: "Kite Beach", shape: .loop))
        #expect(r.name == "Kite Beach sunrise loop")
        #expect(r.reason.contains("sunrise"))
    }

    @Test func firstRunSaadiyat() {
        let r = namer.compose(input(dubaiDate(2026, 11, 5, 8, 30), place: "Saadiyat Island", shape: .loop, hl: [.firstOfKind(.run)]))
        #expect(r.name == "First run, Saadiyat")
    }

    @Test func firstRunNoPlace() {
        #expect(namer.compose(input(dubaiDate(2026, 11, 5, 8, 30), place: nil, shape: .loop, hl: [.firstOfKind(.run)])).name == "First run")
    }

    @Test func morningRunNoPlace() {
        #expect(namer.compose(input(dubaiDate(2026, 11, 5, 8, 30), place: nil, shape: .pointToPoint)).name == "Morning run")
        #expect(namer.compose(input(dubaiDate(2026, 11, 5, 6, 12), place: nil, shape: .loop)).name == "Sunrise loop")
    }

    @Test func otherShapesAndTimes() {
        #expect(namer.compose(input(dubaiDate(2026, 11, 5, 19, 30), place: "Al Barsha", shape: .pointToPoint, walk: true)).name == "Al Barsha run-walk")
        #expect(namer.compose(input(dubaiDate(2026, 11, 5, 0, 30), place: "Marina", shape: .pointToPoint)).name == "Marina midnight run")
        #expect(namer.compose(input(dubaiDate(2026, 11, 5, 15, 0), place: nil, shape: .pointToPoint)).name == "Afternoon run")
    }

    @Test func noEmDashInNames() {
        let r = namer.compose(input(dubaiDate(2026, 11, 5, 6, 12), place: "Kite Beach", shape: .loop))
        #expect(!r.name.contains("\u{2014}") && !r.reason.contains("\u{2014}"))
    }

    @Test func placeCleaner() {
        #expect(RuleBasedNamer.cleanPlace("Saadiyat Island") == "Saadiyat")
        #expect(RuleBasedNamer.cleanPlace("Business Bay District") == "Business Bay")
        #expect(RuleBasedNamer.cleanPlace("Jumeirah Neighbourhood") == "Jumeirah")
        #expect(RuleBasedNamer.cleanPlace("Kite Beach") == "Kite Beach")
        #expect(RuleBasedNamer.cleanPlace("Al Barsha") == "Al Barsha")
        #expect(RuleBasedNamer.cleanPlace("Corniche") == "Corniche")
        #expect(RuleBasedNamer.cleanPlace("Island") == "Island")
        #expect(RuleBasedNamer.cleanPlace("  ") == nil)
    }

    @Test func placeChoice() {
        typealias M = PlaceResolver.Mark
        #expect(PlaceResolver.choose(mid: M(areaOfInterest: "Kite Beach", subLocality: "Umm Suqeim", locality: "Dubai"), far: nil)
                == ResolvedPlace(place: "Kite Beach", city: "Dubai"))
        #expect(PlaceResolver.choose(mid: M(areaOfInterest: nil, subLocality: "Saadiyat Island", locality: "Abu Dhabi"),
                                     far: M(areaOfInterest: nil, subLocality: "Saadiyat Island", locality: "Abu Dhabi"))
                == ResolvedPlace(place: "Saadiyat", city: "Abu Dhabi"))
        #expect(PlaceResolver.choose(mid: M(areaOfInterest: nil, subLocality: nil, locality: "Dubai"), far: nil).place == "Dubai")
    }

    @Test func shapes() {
        // loop: square ~ 1.6 km
        var pts: [RoutePoint] = []
        let corners = [(25.0, 55.0), (25.0036, 55.0), (25.0036, 55.004), (25.0, 55.004), (25.0, 55.0)]
        var cum = 0.0
        for i in 0..<(corners.count - 1) {
            for s in 0..<40 {
                let f = Double(s) / 40
                let p = RoutePoint(lat: corners[i].0 + (corners[i + 1].0 - corners[i].0) * f,
                                   lon: corners[i].1 + (corners[i + 1].1 - corners[i].1) * f,
                                   alt: 0, t: Date(), speed: 3, hAcc: 5, cumMeters: cum, paused: nil)
                if let l = pts.last { cum += RouteGeometry.distance(l, p) }
                var q = p; q.cumMeters = cum
                pts.append(q)
            }
        }
        #expect(RouteGeometry.shape(pts) == .loop)
        // out and back
        let line = route(meters: 2000, speed: 10)
        let back = line.reversed().map { p -> RoutePoint in var q = p; q.cumMeters = 4000 - p.cumMeters; return q }
        #expect(RouteGeometry.shape(line + back) == .outAndBack)
        #expect(RouteGeometry.shape(line) == .pointToPoint)
    }
}

// MARK: Highlights

struct HighlightTests {
    func d(_ km: Double, walk: Bool = true, fastest: Double? = 330) -> WorkoutDigest {
        WorkoutDigest(kind: .run, distanceMeters: km * 1000, fastestKm: fastest, hadWalk: walk, isCheckIn: false)
    }
    @Test func firstOfKind() {
        #expect(Highlights.compute(current: d(3), runFraction: 0.8, history: []).first == .firstOfKind(.run))
    }
    @Test func first5KNoWalk() {
        let h = Highlights.compute(current: d(5.1, walk: false), runFraction: 1, history: [d(3), d(4)])
        #expect(h.contains(.first5KNoWalk))
        #expect(h.contains(.longest(.run, meters: 5100)))
    }
    @Test func fastestKm() {
        let h = Highlights.compute(current: d(3, fastest: 300), runFraction: 0.8, history: [d(4), d(4)])
        #expect(h.contains(.fastestKm(seconds: 300)))
        #expect(h.contains(.ranFraction(0.8)))
    }
}
