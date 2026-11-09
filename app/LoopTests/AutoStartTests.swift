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

private final class ScriptedHistory: MotionHistoryProvider {
    var samples: [ActivityHistorySample]
    var authorized = true
    init(_ s: [ActivityHistorySample]) { samples = s }
    var isAuthorized: Bool { authorized }
    var queries = 0
    func activities(from: Date, to: Date) async -> [ActivityHistorySample] { queries += 1; return samples.filter { $0.start <= to } }
    func pedometer(from: Date, to: Date) async -> (steps: Int, distance: Double?, floors: Int?)? {
        let m = to.timeIntervalSince(from) / 60
        return (Int(m * 110), m * 80, nil)
    }
}

@MainActor
struct StillConfirmTests {
    /// Auto walk with evidence to `t`, then nothing until t+25 min, when a late fix arrives.
    private func run(history: ScriptedHistory) async throws -> (fired: [AutoStop.Reason], r: WorkoutRecorder, t: Date, late: Date, result: RecordingResult?) {
        let clock = HandClock(t0)
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        r.history = history
        var fired: [AutoStop.Reason] = []
        var result: RecordingResult?
        r.onAutoStop = { reason in fired.append(reason); result = r.finishAuto(reason) }
        r.startAuto(kind: .run, from: t0, preroll: [])
        for i in 0...200 {
            clock.t = t0.addingTimeInterval(Double(i) * 3)
            r.ingest(fix(clock.t, north: Double(i) * 4.2, speed: 1.4))
        }
        let t = clock.t
        clock.t = t.addingTimeInterval(1500)
        let late = clock.t
        r.ingest(fix(late, north: 3000, speed: 1.4))
        #expect(r.confirming || !fired.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        return (fired, r, t, late, result)
    }

    @Test func keptWalkingThroughTheGapDoesNotStop() async throws {
        let o = try await run(history: ScriptedHistory([h(30, .walking, now: t0)]))
        #expect(o.fired.isEmpty)
        #expect(o.r.state == .recording && !o.r.confirming)
        o.r.checkAutoStop()
        #expect(o.fired.isEmpty, "the anchor moved forward")
        let res = o.r.finish()
        #expect(res.movingSeconds >= 600 + 1500 - 15, "\(res.movingSeconds)")
        #expect(res.route.last?.t == o.late, "the held fix was replayed")
    }

    @Test func stationaryAfterAMinuteStopsThere() async throws {
        let walkStart = t0.addingTimeInterval(-60)
        let tEnd = t0.addingTimeInterval(600)
        let o = try await run(history: ScriptedHistory([
            .init(start: walkStart, kind: .walking, confidence: .high),
            .init(start: tEnd.addingTimeInterval(60), kind: .stationary, confidence: .high)]))
        #expect(o.fired == [.still])
        #expect(o.result?.end == o.t.addingTimeInterval(60))
        #expect(o.result?.route.contains { $0.t == o.late } == false, "the late fix is dropped")
    }

    @Test func unauthorizedFallsBackToLastEvidence() async throws {
        let hist = ScriptedHistory([h(30, .walking, now: t0)])
        hist.authorized = false
        let o = try await run(history: hist)
        #expect(o.fired == [.still])
        #expect(o.result?.end == o.t)
    }

    @Test func samplesFlowingWithoutMovementStopAtOnce() {
        let clock = HandClock(t0)
        let src = PushSource()
        let r = WorkoutRecorder(location: src, motion: src, clock: clock)
        let hist = ScriptedHistory([h(30, .walking, now: t0)])
        r.history = hist
        var fired: [AutoStop.Reason] = []
        var result: RecordingResult?
        r.onAutoStop = { reason in fired.append(reason); result = r.finishAuto(reason) }
        r.startAuto(kind: .run, from: t0, preroll: [])
        for i in 0...200 {
            clock.t = t0.addingTimeInterval(Double(i) * 3)
            r.ingest(fix(clock.t, north: Double(i) * 4.2, speed: 1.4))
        }
        let t = clock.t
        for i in 1...310 {   // standing: a fix every second, same place, no speed
            clock.t = t.addingTimeInterval(Double(i))
            r.ingest(fix(clock.t, north: 840, speed: 0))
            if !fired.isEmpty { break }
        }
        #expect(fired == [.still])
        #expect(!r.confirming && hist.queries == 0, "no motion-record query")
        #expect(result?.end == t)
    }

    @Test func verdictRules() {
        let t = t0
        // Walking throughout: moving, evidence every 10 s.
        guard case .moving(let ev, let last) = StillCheck.decide([.init(start: t.addingTimeInterval(-60), kind: .walking, confidence: .medium)],
                                                                 lastEvidence: t, now: t.addingTimeInterval(600)) else { Issue.record("not moving"); return }
        #expect(ev.count == 60 && last == t.addingTimeInterval(600))
        // Low confidence counts as not moving.
        #expect(StillCheck.decide([.init(start: t, kind: .walking, confidence: .low)], lastEvidence: t, now: t.addingTimeInterval(600))
                == .still(cut: t, evidence: []))
    }
}

struct GPSLessTests {
    @Test func noFixSavesPedometerDistanceAsMotion() {
        let r = RecordingResult(kind: .run, start: t0, end: t0.addingTimeInterval(1800), movingSeconds: 1800,
                                distanceMeters: 700, steps: 3000, route: [], segments: [], pedometerMeters: 2400)
        let out = AutoStop.final(r)
        #expect(out?.source == "motion" && out?.distanceMeters == 2400 && out?.kind == .walk)
    }

    @Test func withFixesUnchanged() {
        let p = RoutePoint(lat: 25, lon: 55, alt: 0, t: t0, speed: 1, hAcc: 5, cumMeters: 0, paused: nil)
        var q = p; q.t = t0.addingTimeInterval(1800); q.cumMeters = 2000
        let r = RecordingResult(kind: .run, start: t0, end: q.t, movingSeconds: 1800, distanceMeters: 2000, steps: nil,
                                route: [p, q], segments: [], pedometerMeters: 2400)
        let out = AutoStop.final(r)
        #expect(out?.source == "recorded" && out?.distanceMeters == 2000)
    }
}

@MainActor
struct RepairTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Workout.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private let night = Date(timeIntervalSince1970: 1_794_161_280) // 2026-11-08T18:08Z
    private let day9 = Date(timeIntervalSince1970: 1_794_229_200)  // 2026-11-09T13:00Z
    private var w8: Repairs.Window { Repairs.windows[0] }
    private var w9: Repairs.Window { Repairs.windows[1] }

    private func piece(_ minutesAfter: Double, route: Bool = false, source: String = "recorded", base: Date? = nil,
                       kind: ActivityKind = .walk) -> Workout {
        let s = (base ?? night).addingTimeInterval(minutesAfter * 60)
        let pts = route ? [RoutePoint(lat: 25, lon: 55, alt: 0, t: s, speed: 1, hAcc: 5, cumMeters: 0, paused: nil)] : []
        let w = Workout(kind: kind, startDate: s, endDate: s.addingTimeInterval(606), movingSeconds: 618, distanceMeters: 600, route: pts)
        w.source = source
        return w
    }

    /// A fake Health: records deletes, fails the ids in `failing`, lists `stored` (uuid, start).
    private final class FakeHealth {
        var deleted: [UUID] = []
        var failing: Set<UUID> = []
        var stored: [(UUID, Date)] = []
        var ops: Repairs.HealthOps {
            Repairs.HealthOps(delete: { id in
                if self.failing.contains(id) { return false }
                self.deleted.append(id); return true
            }, loopWorkouts: { from, to in self.stored.filter { $0.1 >= from && $0.1 <= to }.map(\.0) })
        }
    }

    private func walkHistory(_ start: Date, minutes: Double) -> ScriptedHistory {
        ScriptedHistory([.init(start: start.addingTimeInterval(-600), kind: .stationary, confidence: .high),
                         .init(start: start, kind: .walking, confidence: .high),
                         .init(start: start.addingTimeInterval(minutes * 60), kind: .stationary, confidence: .high)])
    }

    private func tempDefaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test func selector8Nov() {
        let a = piece(10), b = piece(40)
        let all = [a, b, piece(70, route: true), piece(90, source: "motion"), piece(-60 * 5), piece(60 * 4)]
        #expect(Set(Repairs.pieces(all, in: w8).map(\.id)) == Set([a.id, b.id]))
    }

    @Test func selector9NovIncludesTheRun() {
        let p40 = piece(87, base: day9), p41 = piece(103, base: day9), p42 = piece(117, base: day9)
        let p45 = piece(290, base: day9, kind: .run)
        let all = [p40, p41, p42, p45, piece(60, route: true, base: day9), piece(70, source: "motion", base: day9),
                   piece(-30, base: day9), piece(6 * 60 + 5, base: day9)]
        #expect(Set(Repairs.pieces(all, in: w9).map(\.id)) == Set([p40.id, p41.id, p42.id, p45.id]))
    }

    @Test func repairReplacesPiecesWithOneWalk() async throws {
        let c = try container(), ctx = c.mainContext
        let pieces = [piece(10), piece(30), piece(50)]
        pieces[2].healthKitID = UUID()
        pieces.forEach { ctx.insert($0) }
        try ctx.save()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dismissed = DismissedStore(url: dir.appendingPathComponent("d.json"))
        dismissed.add(start: night.addingTimeInterval(600), end: night.addingTimeInterval(1200), now: night)
        let mh = MotionHistory(provider: walkHistory(night, minutes: 118), dismissed: dismissed)
        let d = tempDefaults(), hk = FakeHealth()
        #expect(await Repairs.repair(w8, ctx, history: mh, defaults: d, log: nil, health: hk.ops))
        #expect(hk.deleted == [pieces[2].healthKitID!])
        let all = try ctx.fetch(FetchDescriptor<Workout>())
        #expect(all.count == 1 && all.first?.source == "motion" && all.first?.startDate == night)
        #expect(d.bool(forKey: w8.repairKey))
        #expect(await Repairs.repair(w8, ctx, history: mh, defaults: d, log: nil, health: hk.ops) == false, "runs once")
    }

    @Test func failedHealthDeleteKeepsPieceAndRetries() async throws {
        let c = try container(), ctx = c.mainContext
        let ok = piece(90, base: day9), bad = piece(110, base: day9)
        ok.healthKitID = UUID(); bad.healthKitID = UUID()
        ctx.insert(ok); ctx.insert(bad); try ctx.save()
        let mh = MotionHistory(provider: walkHistory(day9.addingTimeInterval(85 * 60), minutes: 40), dismissed: nil)
        let d = tempDefaults(), hk = FakeHealth()
        hk.failing = [bad.healthKitID!]
        #expect(await Repairs.repair(w9, ctx, history: mh, defaults: d, log: nil, health: hk.ops) == false)
        var all = try ctx.fetch(FetchDescriptor<Workout>())
        #expect(all.map(\.id) == [bad.id], "the failed one stays, the other went")
        #expect(!d.bool(forKey: w9.repairKey))
        #expect(!all.contains { $0.source == "motion" }, "no rescan yet")
        hk.failing = []
        #expect(await Repairs.repair(w9, ctx, history: mh, defaults: d, log: nil, health: hk.ops))
        all = try ctx.fetch(FetchDescriptor<Workout>())
        #expect(all.count == 1 && all.first?.source == "motion")
        #expect(d.bool(forKey: w9.repairKey))
    }

    @Test func sweepDeletesOnlyUnreferencedInWindow() async throws {
        let c = try container(), ctx = c.mainContext
        let kept = piece(70, route: true); kept.healthKitID = UUID()
        ctx.insert(kept); try ctx.save()
        let orphan = UUID(), outside = UUID()
        let hk = FakeHealth()
        hk.stored = [(kept.healthKitID!, kept.startDate), (orphan, night.addingTimeInterval(100 * 60)),
                     (outside, night.addingTimeInterval(-86400))]
        let d = tempDefaults()
        #expect(await Repairs.sweep(w8, ctx, defaults: d, log: nil, health: hk.ops) == false, "waits for the repair")
        d.set(true, forKey: w8.repairKey)
        #expect(await Repairs.sweep(w8, ctx, defaults: d, log: nil, health: hk.ops))
        #expect(hk.deleted == [orphan])
        #expect(await Repairs.sweep(w8, ctx, defaults: d, log: nil, health: hk.ops) == false, "once")
    }

    @Test func doneRepairDoesNotRerunButItsSweepRunsOnce() async throws {
        let c = try container(), ctx = c.mainContext
        let late = piece(30); ctx.insert(late); try ctx.save()   // a GPS-less piece that must now be left alone
        let d = tempDefaults()
        d.set(true, forKey: w8.repairKey)
        d.set(true, forKey: w9.repairKey); d.set(true, forKey: w9.sweepKey)
        let hk = FakeHealth()
        let orphan = UUID()
        hk.stored = [(orphan, night.addingTimeInterval(110 * 60))]
        let mh = MotionHistory(provider: walkHistory(night, minutes: 118), dismissed: nil)
        await Repairs.runAll(ctx, history: mh, defaults: d, log: nil, health: hk.ops)
        #expect(try ctx.fetchCount(FetchDescriptor<Workout>()) == 1, "repair did not run again")
        #expect(hk.deleted == [orphan] && d.bool(forKey: w8.sweepKey))
        #expect(Repairs.repairsAttempted)
        await Repairs.runAll(ctx, history: mh, defaults: d, log: nil, health: hk.ops)
        #expect(hk.deleted == [orphan], "sweep once")
    }

    @Test func emptyMotionRecordDeletesNothing() async throws {
        let c = try container(), ctx = c.mainContext
        ctx.insert(piece(10)); try ctx.save()
        let d = tempDefaults()
        let ok = await Repairs.repair(w8, ctx, history: MotionHistory(provider: ScriptedHistory([]), dismissed: nil),
                                      defaults: d, log: nil, health: FakeHealth().ops)
        #expect(!ok && !d.bool(forKey: w8.repairKey))
        #expect(try ctx.fetchCount(FetchDescriptor<Workout>()) == 1)
    }

    @Test func healthRetryNeverPicksRepairPieces() {
        let p = piece(10), p9 = piece(300, base: day9, kind: .run)
        #expect(Repairs.healthRetryCandidates([p9], now: day9.addingTimeInterval(3600 * 8), healthOn: true).isEmpty)
        #expect(Repairs.healthRetryCandidates([p], now: night.addingTimeInterval(3600), healthOn: true).isEmpty)
        let gps = piece(20, route: true)
        #expect(Repairs.healthRetryCandidates([p, gps], now: night.addingTimeInterval(3600), healthOn: true).map(\.id) == [gps.id])
    }

    @Test func healthRetrySelection() {
        let now = night.addingTimeInterval(86400)
        let missing = piece(-60 * 6)
        let saved = piece(20); saved.healthKitID = UUID()
        let motion = piece(40, source: "motion")
        let old = piece(-8 * 1440)
        let checkIn = piece(60); checkIn.isCheckIn = true
        let all = [missing, saved, motion, old, checkIn]
        #expect(Repairs.healthRetryCandidates(all, now: now, healthOn: true).map(\.id) == [missing.id])
        #expect(Repairs.healthRetryCandidates(all, now: now, healthOn: false).isEmpty)
    }
}
