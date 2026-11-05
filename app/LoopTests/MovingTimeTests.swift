import Testing
import Foundation
import SwiftData
@testable import Loop

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Route points: walking adds 1.2 m a second; standing keeps fixes coming with no distance or speed.
/// `plan` is a list of (seconds, moving).
private func route(_ plan: [(Double, Bool)]) -> [RoutePoint] {
    var pts: [RoutePoint] = []
    var t = 0.0, cum = 0.0
    for (secs, moving) in plan {
        for _ in 0..<Int(secs) {
            t += 1
            if moving { cum += 1.2 }
            pts.append(RoutePoint(lat: 24.5 + cum / 111_195, lon: 54.4, alt: 0, t: t0.addingTimeInterval(t),
                                  speed: moving ? 1.2 : 0.02, hAcc: moving ? 4 : 8, cumMeters: cum, paused: nil))
        }
    }
    return pts
}

private final class SilentSource: LocationSource, MotionSource {
    func fixes() -> AsyncStream<LocationFix> { AsyncStream { _ in } }
    func activities() -> AsyncStream<MotionSample> { AsyncStream { _ in } }
    func pedometer(from start: Date) -> AsyncStream<PedometerSample> { AsyncStream { _ in } }
    func stop() {}
}

/// A clock the test moves by hand.
private final class ManualClock: RecordingClock, @unchecked Sendable {
    var t: Date
    init(_ t: Date) { self.t = t; super.init(scale: 1, origin: t) }
    override func now() -> Date { t }
}

struct MovingTimeTests {

    /// Criterion 1: the user's evening shape. 33 min walk, 38 min stop, 18 min walk, 9 min stop, 13 min walk.
    @Test func longStopsAddAtMostGrace() {
        let pts = route([(33 * 60, true), (38 * 60, false), (18 * 60, true), (9 * 60, false), (13 * 60, true)])
        let s = MovingTime.seconds(start: t0, end: pts.last!.t, route: pts)
        #expect(s >= 64 * 60 && s <= 64 * 60 + 24)
    }

    /// Criterion 2.
    @Test func continuousMovementCountsFully() {
        let pts = route([(30 * 60, true)])
        let s = MovingTime.seconds(start: t0, end: pts.last!.t, route: pts)
        #expect(abs(s - 30 * 60) <= 1)
    }

    @Test func slowWalkWithSparseEvidence() {
        var m = MovingTime()
        m.begin(t0)
        for i in stride(from: 5.0, through: 600, by: 5) { m.evidence(t0.addingTimeInterval(i)) }
        #expect(m.value(at: t0.addingTimeInterval(600)) == 600)
    }

    @Test func stopOfExactlyGraceCountsFully() {
        var m = MovingTime()
        m.begin(t0)
        m.evidence(t0.addingTimeInterval(12))
        m.evidence(t0.addingTimeInterval(24))
        #expect(m.total == 24)
        #expect(!m.isStill(at: t0.addingTimeInterval(36)))
        #expect(m.isStill(at: t0.addingTimeInterval(37)))
    }

    /// Criterion 3: indoors, steps but no GPS movement.
    @Test func stepsAloneCountAsMoving() {
        let pedo = (0...600).map { PedometerSample(time: t0.addingTimeInterval(Double($0)), steps: $0 * 2, cadence: 120) }
        let still = (0..<600).map { RoutePoint(lat: 24.5, lon: 54.4, alt: 0, t: t0.addingTimeInterval(Double($0)),
                                               speed: 0, hAcc: 40, cumMeters: 0, paused: nil) }
        let m = MovingTime.replay(start: t0, end: t0.addingTimeInterval(600), points: still, pedo: pedo, usesSteps: true)
        #expect(abs(m.total - 600) <= 1)
        // A ride ignores steps.
        let ride = MovingTime.replay(start: t0, end: t0.addingTimeInterval(600), points: still, pedo: pedo, usesSteps: false)
        #expect(ride.total <= 24)
    }

    @Test func pauseInsideAStopAndPausedPoints() {
        // Walk 60 s, stand 30 s, pause 300 s (GPS on, paused points), walk 60 s.
        var pts = route([(60, true), (30, false)])
        let last = pts.last!
        for i in 1...300 {
            pts.append(RoutePoint(lat: last.lat, lon: last.lon, alt: 0, t: last.t.addingTimeInterval(Double(i)),
                                  speed: 2, hAcc: 4, cumMeters: last.cumMeters, paused: true))
        }
        let after = pts.last!
        for i in 1...60 {
            pts.append(RoutePoint(lat: after.lat, lon: after.lon, alt: 0, t: after.t.addingTimeInterval(Double(i)),
                                  speed: 1.2, hAcc: 4, cumMeters: after.cumMeters + Double(i) * 1.2, paused: nil))
        }
        let s = MovingTime.seconds(start: t0, end: pts.last!.t, route: pts)
        // 60 s walking + 12 s grace into the stop + 60 s walking; the pause adds nothing.
        #expect(s >= 132 && s <= 133)
    }

    @Test func emptyAndSinglePoint() {
        #expect(MovingTime.seconds(start: t0, end: t0.addingTimeInterval(600), route: []) == 12)
        let one = route([(1, true)])
        #expect(MovingTime.seconds(start: t0, end: t0.addingTimeInterval(600), route: one) <= 13)
    }
}

@MainActor
struct MovingTimeRecorderTests {

    private func fix(_ meters: Double, at t: Date, speed: Double) -> LocationFix {
        LocationFix(lat: 24.5 + meters / 111_195, lon: 54.4, altitude: 0, speed: speed, hAcc: 5, timestamp: t,
                    isStationary: false)
    }

    /// Criterion 5: live time never decreases and freezes during a stop; the saved result matches.
    @Test func liveFreezesWhenStill() {
        let clock = ManualClock(t0)
        let src = SilentSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        r.start(kind: .walk)
        var prev = 0.0, meters = 0.0
        func tick(_ moving: Bool) {
            clock.t = clock.t.addingTimeInterval(1)
            if moving { meters += 1.3 }
            r.ingest(fix(meters, at: clock.t, speed: moving ? 1.3 : 0.01))
            r.tickForTests()
            #expect(r.movingSeconds >= prev)
            prev = r.movingSeconds
        }
        for _ in 0..<120 { tick(true) }
        #expect(abs(r.movingSeconds - 120) <= 1)
        for _ in 0..<12 { tick(false) }
        let frozen = r.movingSeconds
        for _ in 0..<300 { tick(false) }
        #expect(r.movingSeconds == frozen)
        #expect(r.isStill)
        for _ in 0..<60 { tick(true) }
        #expect(!r.isStill)
        #expect(abs(r.movingSeconds - (180 + 12)) <= 2)

        // Criterion 4: a 5 minute manual pause counts 0.
        r.pause()
        let atPause = r.movingSeconds
        clock.t = clock.t.addingTimeInterval(300)
        r.tickForTests()
        #expect(r.movingSeconds == atPause)
        r.resume()
        for _ in 0..<30 { tick(true) }
        // Finishing while still.
        for _ in 0..<100 { tick(false) }
        let res = r.finish()
        #expect(abs(res.movingSeconds - (atPause + 30 + 12)) <= 2)
        #expect(res.movingSeconds <= res.end.timeIntervalSince(res.start) - 300)
    }

    @Test func stepsKeepRecorderMoving() {
        let clock = ManualClock(t0)
        let src = SilentSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        r.start(kind: .walk)
        for i in 1...300 {
            clock.t = t0.addingTimeInterval(Double(i))
            r.ingestPedometer(PedometerSample(time: clock.t, steps: i * 2, cadence: 120))
        }
        r.tickForTests()
        #expect(!r.isStill)
        #expect(abs(r.finish().movingSeconds - 300) <= 2)
    }
}

/// Criterion 6.
@MainActor
struct MovingTimeCorrectionTests {

    @Test func correctsOnceAndOnlyRecorded() throws {
        let container = try ModelContainer(for: Workout.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        let defaults = UserDefaults(suiteName: "moving-\(UUID().uuidString)")!

        let stopPts = route([(33 * 60, true), (38 * 60, false), (18 * 60, true), (9 * 60, false), (13 * 60, true)])
        let stopped = Workout(kind: .walk, startDate: t0, endDate: stopPts.last!.t, movingSeconds: 111 * 60,
                              distanceMeters: stopPts.last!.cumMeters, route: stopPts)
        let contPts = route([(30 * 60, true)])
        let cont = Workout(kind: .walk, startDate: t0, endDate: contPts.last!.t, movingSeconds: 30 * 60,
                           distanceMeters: contPts.last!.cumMeters, route: contPts)
        let motion = Workout(kind: .walk, startDate: t0, endDate: stopPts.last!.t, movingSeconds: 111 * 60,
                             distanceMeters: 1000, route: stopPts)
        motion.source = "motion"
        let checkIn = Workout(kind: .walk, startDate: t0, endDate: stopPts.last!.t, movingSeconds: 111 * 60,
                              distanceMeters: 0, isCheckIn: true, route: stopPts)
        for w in [stopped, cont, motion, checkIn] { ctx.insert(w) }
        try ctx.save()
        let distance = stopped.distanceMeters

        #expect(WorkoutStore.correctMovingTimeOnce(ctx, defaults: defaults) == 1)
        #expect(stopped.movingSeconds >= 64 * 60 && stopped.movingSeconds <= 64 * 60 + 24)
        #expect(stopped.distanceMeters == distance)
        #expect(cont.movingSeconds == 30 * 60)
        #expect(motion.movingSeconds == 111 * 60)
        #expect(checkIn.movingSeconds == 111 * 60)

        // Does not run twice.
        stopped.movingSeconds = 111 * 60
        #expect(WorkoutStore.correctMovingTimeOnce(ctx, defaults: defaults) == 0)
        #expect(stopped.movingSeconds == 111 * 60)
    }

    /// Local only: what the correction computes for a real route (LOOP_REAL_ROUTE). Never committed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOP_REAL_ROUTE"] != nil))
    func realRouteCorrection() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOOP_REAL_ROUTE"]!)
        let pts = try JSONDecoder().decode([RoutePoint].self, from: Data(contentsOf: url))
        let wall = pts.last!.t.timeIntervalSince(pts[0].t)
        let s = MovingTime.seconds(start: pts[0].t, end: pts.last!.t, route: pts)
        let km = pts.last!.cumMeters / 1000
        print("real route wall", wall, "moving", s, "km", km, "pace s/km old", wall / km, "new", s / km)
    }
}
