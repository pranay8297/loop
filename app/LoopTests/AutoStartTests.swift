import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import Loop

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private final class HandClock: RecordingClock, @unchecked Sendable {
    var t: Date
    init(_ t: Date) { self.t = t; super.init(scale: 1, origin: t) }
    override func now() -> Date { t }
}

/// Sources the test drives by hand: activity samples are pushed through `act`.
private final class PushSource: LocationSource, MotionSource {
    var act: AsyncStream<MotionSample>.Continuation?
    var pedometerFrom: Date?
    func fixes() -> AsyncStream<LocationFix> { AsyncStream { _ in } }
    func activities() -> AsyncStream<MotionSample> { AsyncStream { self.act = $0 } }
    func pedometer(from start: Date) -> AsyncStream<PedometerSample> { pedometerFrom = start; return AsyncStream { _ in } }
    func stop() {}
}

private func h(_ minutesAgo: Double, _ kind: ActivityHistorySample.Kind, _ c: MotionConfidence = .high, now: Date = t0) -> ActivityHistorySample {
    .init(start: now.addingTimeInterval(-minutesAgo * 60), kind: kind, confidence: c)
}

private func fix(_ t: Date, north meters: Double, speed: Double) -> LocationFix {
    LocationFix(lat: 25.0 + meters / 111_195, lon: 55.0, altitude: 0, speed: speed, hAcc: 5, timestamp: t, isStationary: false)
}

struct AutoStartPolicyTests {
    @Test func fourOfFiveMinutesWalkingStartsOnFoot() {
        let d = AutoStartPolicy.decide([h(9, .stationary), h(4, .walking, .medium)], now: t0, recording: false)
        #expect(d == .start(kind: .run, from: t0.addingTimeInterval(-240)))
    }

    @Test func twoMinutesWalkingIsNotEnough() {
        let d = AutoStartPolicy.decide([h(9, .stationary), h(2, .walking, .medium)], now: t0, recording: false)
        #expect(d == .ignore("only 2 min on foot"))
    }

    @Test func oneMinuteRunningStarts() {
        let d = AutoStartPolicy.decide([h(9, .stationary), h(1, .running, .high)], now: t0, recording: false)
        guard case .start(let k, _) = d else { Issue.record("no start: \(d)"); return }
        #expect(k == .run)
    }

    @Test func cyclingStartsARide() {
        let d = AutoStartPolicy.decide([h(9, .stationary), h(1.5, .cycling, .medium)], now: t0, recording: false)
        guard case .start(let k, _) = d else { Issue.record("no start: \(d)"); return }
        #expect(k == .ride)
    }

    @Test func automotiveInLastTwoMinutesNeverStarts() {
        let d = AutoStartPolicy.decide([h(6, .walking), h(1.5, .automotive, .low), h(1, .walking)], now: t0, recording: false)
        #expect(d == .ignore("in a car"))
    }

    @Test func stationaryOrLowConfidenceDoesNotStart() {
        #expect(AutoStartPolicy.decide([h(10, .stationary)], now: t0, recording: false) == .ignore("not moving"))
        #expect(AutoStartPolicy.decide([h(10, .walking, .low)], now: t0, recording: false) == .ignore("not moving"))
        #expect(AutoStartPolicy.decide([], now: t0, recording: false) == .ignore("not moving"))
    }

    @Test func alreadyRecordingDoesNotStart() {
        #expect(AutoStartPolicy.decide([h(5, .running)], now: t0, recording: true) == .ignore("already recording"))
    }

    @Test func startIsCappedAtFifteenMinutes() {
        let from = AutoStartPolicy.startOfMovement([h(40, .walking)], now: t0)
        #expect(from == t0.addingTimeInterval(-900))
    }

    @Test func prerollSpreadsStepsAndMetres() {
        let p = AutoStartPolicy.preroll(from: t0, to: t0.addingTimeInterval(60), steps: 120, meters: 90)
        #expect(p.count == 6)
        #expect(p.last?.steps == 120 && p.last?.distance == 90 && p.last?.time == t0.addingTimeInterval(60))
        let none = AutoStartPolicy.preroll(from: t0, to: t0.addingTimeInterval(30), steps: 0, meters: nil)
        #expect(none.allSatisfy { $0.steps == 0 && $0.distance == nil })
    }
}

struct AutoStopRuleTests {
    @Test func fiveMinutesStillStops() {
        #expect(AutoStop.check(now: t0.addingTimeInterval(300), start: t0, lastEvidence: t0, automotiveSince: nil) == .still)
        #expect(AutoStop.check(now: t0.addingTimeInterval(299), start: t0, lastEvidence: t0, automotiveSince: nil) == nil)
    }

    @Test func carForMoreThanAMinuteStops() {
        let now = t0.addingTimeInterval(1000)
        #expect(AutoStop.check(now: now, start: t0, lastEvidence: now, automotiveSince: now.addingTimeInterval(-61)) == .car)
        #expect(AutoStop.check(now: now, start: t0, lastEvidence: now, automotiveSince: now.addingTimeInterval(-30)) == nil)
    }

    @Test func threeHourCap() {
        let now = t0.addingTimeInterval(3 * 3600)
        #expect(AutoStop.check(now: now, start: t0, lastEvidence: now, automotiveSince: nil) == .cap)
    }

    private func result(_ kind: ActivityKind, moving: Double, distance: Double, run: Double) -> RecordingResult {
        let r1 = RoutePoint(lat: 25, lon: 55, alt: 0, t: t0, speed: 1, hAcc: 5, cumMeters: 0, paused: nil)
        var r2 = r1; r2.t = t0.addingTimeInterval(moving); r2.cumMeters = distance
        let segs = [MoveSegment(kind: .walk, startMeters: 0, endMeters: distance - run, startTime: t0, endTime: t0),
                    MoveSegment(kind: .run, startMeters: distance - run, endMeters: distance, startTime: t0, endTime: t0)]
        return RecordingResult(kind: kind, start: t0, end: r2.t, movingSeconds: moving, distanceMeters: distance,
                               steps: nil, route: [r1, r2], segments: segs)
    }

    @Test func onFootSavesAsWalkUnderTenPercentRunning() {
        let w = AutoStop.final(result(.run, moving: 1800, distance: 2000, run: 150))
        #expect(w?.kind == .walk)
        #expect(w?.segments.map(\.kind) == [.walk])
        #expect(AutoStop.final(result(.run, moving: 1800, distance: 2000, run: 250))?.kind == .run)
    }

    @Test func underTheMinimumsIsDiscarded() {
        #expect(AutoStop.final(result(.run, moving: 590, distance: 700, run: 0)) == nil)
        #expect(AutoStop.final(result(.run, moving: 290, distance: 900, run: 900)) == nil)
        #expect(AutoStop.final(result(.run, moving: 310, distance: 900, run: 900))?.kind == .run)
        #expect(AutoStop.final(result(.ride, moving: 590, distance: 3000, run: 0)) == nil)
        #expect(AutoStop.final(result(.ride, moving: 610, distance: 3000, run: 0))?.kind == .ride)
    }
}

@MainActor
struct AutoRecorderTests {
    /// Six minutes after the bout began with 500 m on the pedometer, then five minutes of GPS walking.
    @Test func prerollCountsTimeAndDistance() {
        let clock = HandClock(t0.addingTimeInterval(360))
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        let pre = AutoStartPolicy.preroll(from: t0, to: clock.t, steps: 700, meters: 500)
        r.startAuto(kind: .run, from: t0, preroll: pre)
        #expect(r.isAuto)
        #expect(src.pedometerFrom == clock.t, "live steps count from the GPS start; the pre-roll is added on top")
        let gpsStart = clock.t
        for i in 0...100 {
            clock.t = gpsStart.addingTimeInterval(Double(i) * 3)
            r.ingest(fix(clock.t, north: Double(i) * 4.2, speed: 1.4))
        }
        let res = r.finish()
        #expect(res.start == t0)
        #expect(res.distanceMeters >= 500 + 400 && res.distanceMeters <= 500 + 430, "\(res.distanceMeters)")
        #expect(res.movingSeconds >= 360 + 290, "\(res.movingSeconds)")
    }

    @Test func carTrimsRouteAtLastFootEvidence() async throws {
        let clock = HandClock(t0)
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        var reasons: [AutoStop.Reason] = []
        r.onAutoStop = { reasons.append($0) }
        r.startAuto(kind: .run, from: t0, preroll: [])
        for i in 0...200 {   // 10 minutes walking
            clock.t = t0.addingTimeInterval(Double(i) * 3)
            r.ingest(fix(clock.t, north: Double(i) * 4.2, speed: 1.4))
        }
        let carStart = clock.t.addingTimeInterval(1)
        src.act?.yield(MotionSample(time: carStart, activity: .automotive, confidence: .high))
        try await Task.sleep(for: .milliseconds(50))
        for i in 1...40 {    // 2 minutes at 8 m/s
            clock.t = carStart.addingTimeInterval(Double(i) * 3)
            r.ingest(fix(clock.t, north: 840 + Double(i) * 24, speed: 8))
        }
        r.checkAutoStop()
        #expect(reasons == [.car])
        r.checkAutoStop()
        #expect(reasons == [.car], "fires once")
        let res = r.finishAuto(.car)
        #expect(res.end == carStart)
        #expect(res.route.allSatisfy { $0.t <= carStart })
        #expect(res.distanceMeters <= 850, "\(res.distanceMeters)")
        #expect(res.movingSeconds <= 610, "\(res.movingSeconds)")
        #expect(AutoStop.final(res)?.kind == .walk)
    }

    @Test func stillStopsAtLastMovement() {
        let clock = HandClock(t0)
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        var reasons: [AutoStop.Reason] = []
        r.onAutoStop = { reasons.append($0) }
        r.startAuto(kind: .run, from: t0, preroll: [])
        for i in 0...240 {
            clock.t = t0.addingTimeInterval(Double(i) * 3)
            r.ingest(fix(clock.t, north: Double(i) * 4.2, speed: 1.4))
        }
        let last = clock.t
        clock.t = last.addingTimeInterval(299); r.checkAutoStop()
        #expect(reasons.isEmpty)
        clock.t = last.addingTimeInterval(300); r.checkAutoStop()
        #expect(reasons == [.still])
        let res = r.finishAuto(.still)
        #expect(res.end == last)
        #expect(abs(res.movingSeconds - 720) < 15, "\(res.movingSeconds)")
    }

    @Test func manualRecordingIsNeverAutoStopped() {
        let clock = HandClock(t0)
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        var fired = false
        r.onAutoStop = { _ in fired = true }
        r.start(kind: .walk)
        clock.t = t0.addingTimeInterval(4 * 3600)
        r.checkAutoStop()
        #expect(!fired && !r.isAuto)
        _ = r.finish()
    }

    @Test func manualPauseDisablesAutoStop() {
        let clock = HandClock(t0)
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        var fired = false
        r.onAutoStop = { _ in fired = true }
        r.startAuto(kind: .run, from: t0, preroll: [])
        r.pause()
        clock.t = t0.addingTimeInterval(600)
        r.checkAutoStop()
        #expect(!fired)
        r.resume()
        clock.t = t0.addingTimeInterval(899); r.checkAutoStop()
        #expect(!fired, "the five minutes count from the resume")
        clock.t = t0.addingTimeInterval(900); r.checkAutoStop()
        #expect(fired)
    }

    @Test func draftKeepsAutoFlag() {
        let clock = HandClock(t0.addingTimeInterval(120))
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        r.startAuto(kind: .run, from: t0, preroll: AutoStartPolicy.preroll(from: t0, to: clock.t, steps: 200, meters: 150))
        let d = r.draft()
        #expect(d.auto == true && d.meterOffset == 150 && d.stepOffset == 200)
        let back = WorkoutRecorder.restore(d, location: src, motion: src, clock: clock, paused: false, gap: 0)
        #expect(back.isAuto)
        #expect(back.distanceMeters == 150)
        let manual = WorkoutRecorder(location: src, motion: src, clock: clock)
        manual.start(kind: .walk)
        #expect(manual.draft().auto == nil)
        #expect(!WorkoutRecorder.restore(manual.draft(), location: src, motion: src, clock: clock, paused: true, gap: 0).isAuto)
    }

    @Test func tooShortIsDiscardedAndDraftCleared() throws {
        let container = try ModelContainer(for: Workout.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = RecordingDraftStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID()).json"))
        let clock = HandClock(t0.addingTimeInterval(120))
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        r.draftStore = store
        r.startAuto(kind: .run, from: t0, preroll: AutoStartPolicy.preroll(from: t0, to: clock.t, steps: 200, meters: 150))
        try store.saveNow(r.draft())
        #expect(store.load() != nil)
        let s = Session()
        s.context = container.mainContext
        s.recorder = r
        s.showingCover = true
        clock.t = t0.addingTimeInterval(500)
        s.autoFinish(r, reason: .still)
        #expect(store.load() == nil)
        #expect(s.recorder == nil && !s.showingCover)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Workout>()) == 0)
    }
}

struct MotionRecordTests {
    @Test func stretchesCarryVerdicts() {
        let now = t0
        let s: [ActivityHistorySample] = [
            h(300, .walking, now: now), h(295, .stationary, now: now),    // 5 min: too short
            h(200, .walking, now: now), h(188, .stationary, now: now),    // 12 min: a walk
            h(100, .walking, now: now), h(98, .stationary, now: now),     // 2 min: not listed
            h(50, .automotive, now: now), h(40, .stationary, now: now),   // car: not listed
            h(6, .running, now: now),                                     // still going
        ]
        let out = BoutDetector.stretches(s, now: now)
        #expect(out.map(\.verdict) == [.tooShort, .bout, .open])
        #expect(out.map(\.kind) == [.walk, .walk, .run])
        #expect(out[1].movingSeconds == 720)
        #expect(BoutDetector.detect(s, now: now).bouts.count == 1)
    }

    @Test func outcomes() {
        let st = BoutDetector.Stretch(kind: .walk, start: t0, end: t0.addingTimeInterval(900), movingSeconds: 900, verdict: .bout)
        let rec = MotionRecordRow.Known(start: t0, end: t0.addingTimeInterval(900), recorded: true)
        let logged = MotionRecordRow.Known(start: t0, end: t0.addingTimeInterval(900), recorded: false)
        #expect(MotionRecordRow.outcome(st, workouts: [rec], dismissed: []) == "you recorded this")
        #expect(MotionRecordRow.outcome(st, workouts: [logged], dismissed: []) == "logged")
        #expect(MotionRecordRow.outcome(st, workouts: [], dismissed: [(t0, t0.addingTimeInterval(900))]) == "you said not a workout")
        var short = st; short.verdict = .tooShort
        #expect(MotionRecordRow.outcome(short, workouts: [], dismissed: []) == "too short")
        var open = st; open.verdict = .open
        #expect(MotionRecordRow.outcome(open, workouts: [rec], dismissed: []) == "still going")
    }
}

@MainActor
struct SuspendedQuietTests {
    /// Walks 10 min to `t`, then nothing (no ticks: suspended) until t+20 min, then a late sample.
    private func run(auto: Bool, late: (WorkoutRecorder, Date) -> Void) -> (fired: [AutoStop.Reason], result: RecordingResult?, r: WorkoutRecorder, t: Date) {
        let clock = HandClock(t0)
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        var fired: [AutoStop.Reason] = []
        var result: RecordingResult?
        r.onAutoStop = { reason in fired.append(reason); result = r.finishAuto(reason) }
        if auto { r.startAuto(kind: .run, from: t0, preroll: []) } else { r.start(kind: .run) }
        for i in 0...200 {
            clock.t = t0.addingTimeInterval(Double(i) * 3)
            r.ingest(fix(clock.t, north: Double(i) * 4.2, speed: 1.4))
            r.ingestPedometer(PedometerSample(time: clock.t, steps: i * 5, cadence: 110))
        }
        let t = clock.t
        clock.t = t.addingTimeInterval(1200)
        late(r, clock.t)
        return (fired, result, r, t)
    }

    @Test func lateFixClosesAtLastMovement() {
        let o = run(auto: true) { r, now in r.ingest(fix(now, north: 2000, speed: 1.4)) }
        #expect(o.fired == [.still])
        #expect(o.result?.end == o.t)
        #expect(o.result?.route.allSatisfy { $0.t <= o.t } == true)
        #expect(o.r.state == .finished)
        o.r.checkAutoStop()
        #expect(o.fired == [.still], "fires once")
    }

    @Test func latePedometerClosesAtLastMovement() {
        let o = run(auto: true) { r, now in r.ingestPedometer(PedometerSample(time: now, steps: 5000, cadence: 110)) }
        #expect(o.fired == [.still])
        #expect(o.result?.end == o.t)
        #expect(o.result.map { abs($0.movingSeconds - 600) < 15 } == true)
    }

    @Test func manualRecordingIsNotClosed() {
        let o = run(auto: false) { r, now in
            r.ingest(fix(now, north: 2000, speed: 1.4))
            r.ingestPedometer(PedometerSample(time: now, steps: 5000, cadence: 110))
        }
        #expect(o.fired.isEmpty && o.r.state == .recording)
        _ = o.r.finish()
    }
}

@MainActor
struct ArmingTests {
    private func loc(age: TimeInterval) -> CLLocation {
        CLLocation(coordinate: .init(latitude: 25.1, longitude: 55.2), altitude: 0, horizontalAccuracy: 30,
                   verticalAccuracy: -1, timestamp: t0.addingTimeInterval(-age))
    }

    @Test func freshArmsStaleOrMissingAsksForAFix() {
        #expect(AutoStart.armAction(for: loc(age: 10), delivered: false, now: t0, lastRequest: nil) == .arm(lat: 25.1, lon: 55.2))
        #expect(AutoStart.armAction(for: loc(age: 61), delivered: false, now: t0, lastRequest: nil) == .requestFix)
        #expect(AutoStart.armAction(for: nil, delivered: false, now: t0, lastRequest: nil) == .requestFix)
    }

    @Test func deliveredArmsWhateverItsAge() {
        #expect(AutoStart.armAction(for: loc(age: 300), delivered: true, now: t0, lastRequest: t0) == .arm(lat: 25.1, lon: 55.2))
    }

    @Test func fallbackRequestsAreRateLimited() {
        let stale = loc(age: 300)
        #expect(AutoStart.armAction(for: stale, delivered: false, now: t0, lastRequest: nil) == .requestFix)
        #expect(AutoStart.armAction(for: stale, delivered: false, now: t0.addingTimeInterval(60), lastRequest: t0) == .nothing)
        #expect(AutoStart.armAction(for: nil, delivered: false, now: t0.addingTimeInterval(120), lastRequest: t0) == .nothing)
        #expect(AutoStart.armAction(for: stale, delivered: false, now: t0.addingTimeInterval(121), lastRequest: t0) == .requestFix)
    }
}

struct MonitorNameTests {
    /// CLMonitor aborts the app on a name with anything but letters and digits.
    @MainActor @Test func monitorNameIsAlphanumeric() {
        for name in [AutoStart.monitorName, AutoStart.regionID] {
            #expect(!name.isEmpty)
            #expect(name.unicodeScalars.allSatisfy { ($0.isASCII) && CharacterSet.alphanumerics.contains($0) }, "\(name)")
        }
    }
}
