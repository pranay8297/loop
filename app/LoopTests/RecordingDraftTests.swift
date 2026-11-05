import Testing
import Foundation
@testable import Loop

/// Sources that never deliver anything on their own; tests feed fixes with `ingest`.
private final class SilentSource: LocationSource, MotionSource {
    var pedometerFrom: Date?
    func fixes() -> AsyncStream<LocationFix> { AsyncStream { _ in } }
    func activities() -> AsyncStream<MotionSample> { AsyncStream { _ in } }
    func pedometer(from start: Date) -> AsyncStream<PedometerSample> { pedometerFrom = start; return AsyncStream { _ in } }
    func stop() {}
}

private func tempStore() -> RecordingDraftStore {
    RecordingDraftStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("draft-\(UUID().uuidString)").appendingPathComponent("recording-draft.json"))
}

/// A point `meters` north of a fixed origin.
private func fix(_ meters: Double, at t: Date, hAcc: Double = 5) -> LocationFix {
    LocationFix(lat: 24.5 + meters / 111_195, lon: 54.4, altitude: 0, speed: 3, hAcc: hAcc, timestamp: t, isStationary: false)
}

private func sampleDraft(points n: Int, savedAt: Date = Date()) -> RecordingDraft {
    let start = savedAt.addingTimeInterval(-Double(n))
    var pts: [RoutePoint] = []
    for i in 0..<n {
        let x = Double(i)
        let lat: Double = 24.5 + x * 1e-5
        let paused: Bool? = i % 500 == 0 ? true : nil
        pts.append(RoutePoint(lat: lat, lon: 54.4, alt: 3, t: start.addingTimeInterval(x),
                              speed: 3.1, hAcc: 5, cumMeters: x * 3, paused: paused))
    }
    let modes: [MoveKind] = Array(repeating: .run, count: n)
    return RecordingDraft(kind: .run, startDate: start, pausedTotal: 12, pauseStarted: nil, wasPaused: false,
                          savedAt: savedAt, points: pts, modes: modes,
                          motionSamples: [MotionSample(time: start, activity: .running, confidence: .high)],
                          pedo: [PedometerSample(time: start, steps: 100, cadence: 160, distance: 80)],
                          cum: Double(n) * 3)
}

@MainActor
struct RecordingDraftTests {

    @Test func roundTrip() throws {
        let store = tempStore()
        var d = sampleDraft(points: 50)
        d.pauseStarted = d.savedAt.addingTimeInterval(-5)
        d.wasPaused = true
        try store.saveNow(d)
        #expect(store.load() == d)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func corruptFileIgnoredAndRemoved() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"kind\":\"run\",\"startDa".utf8).write(to: store.url)
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        // An older format missing fields is treated the same way.
        try Data("{\"kind\":\"run\"}".utf8).write(to: store.url)
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func policyBoundaries() {
        #expect(RestorePolicy.decide(age: 0, wasPaused: false) == .resume)
        #expect(RestorePolicy.decide(age: -50, wasPaused: false) == .resume)
        #expect(RestorePolicy.decide(age: 120, wasPaused: false) == .resume)
        #expect(RestorePolicy.decide(age: 121, wasPaused: false) == .restorePaused)
        #expect(RestorePolicy.decide(age: 10, wasPaused: true) == .restorePaused)
        #expect(RestorePolicy.decide(age: 12 * 3600, wasPaused: false) == .restorePaused)
        #expect(RestorePolicy.decide(age: 12 * 3600, wasPaused: true) == .restorePaused)
        #expect(RestorePolicy.decide(age: 12 * 3600 + 1, wasPaused: false) == .autoSave)
        #expect(RestorePolicy.decide(age: 12 * 3600 + 1, wasPaused: true) == .autoSave)
    }

    @Test func resumeExcludesGapAndKeepsRoute() {
        let now = Date()
        // Moving from the start (a point every second) to the save, 900 s before now.
        var d = sampleDraft(points: 600, savedAt: now.addingTimeInterval(-300))
        d.pausedTotal = 0
        let src = SilentSource()
        let r = WorkoutRecorder.restore(d, location: src, motion: src, clock: RecordingClock(),
                                        paused: false, gap: 300)
        #expect(r.state == .recording)
        #expect(src.pedometerFrom == d.startDate)
        #expect(r.distanceMeters == d.cum)
        #expect(r.liveRoute == d.points)
        // 900 s since start minus the 300 s gap.
        #expect(abs(r.movingSeconds - 600) < 2)

        // The first fix after the gap re-anchors: no jump, even far away.
        r.ingest(fix(2_000, at: now))
        #expect(r.draft().cum == d.cum)
        // Then distance counts again.
        r.ingest(fix(2_020, at: now.addingTimeInterval(5)))
        #expect(abs(r.draft().cum - (d.cum + 20)) < 1)

        let res = r.finish()
        #expect(abs(res.movingSeconds - 600) < 3)
        #expect(abs(res.distanceMeters - (d.cum + 20)) < 1)
        #expect(res.route.count == d.points.count + 2)
    }

    @Test func restorePausedStartsPauseAtSave() {
        let now = Date()
        var d = sampleDraft(points: 600, savedAt: now.addingTimeInterval(-600))
        d.pausedTotal = 0
        let src = SilentSource()
        let r = WorkoutRecorder.restore(d, location: src, motion: src, clock: RecordingClock(), paused: true, gap: 600)
        #expect(r.state == .paused)
        #expect(r.closedAt == d.savedAt)
        #expect(abs(r.movingSeconds - 600) < 2)
        r.resume()
        #expect(r.closedAt == nil)
        #expect(abs(r.movingSeconds - 600) < 2)
        // No jump after resuming.
        r.ingest(fix(5_000, at: now))
        #expect(r.draft().cum == d.cum)
    }

    @Test func resultFromDraftMatchesFinish() {
        let src = SilentSource()
        let r = WorkoutRecorder(location: src, motion: src)
        r.start(kind: .run)
        let t0 = Date()
        for i in 0..<60 { r.ingest(fix(Double(i) * 15, at: t0.addingTimeInterval(Double(i) * 5))) }
        let d = r.draft()
        let fromDraft = WorkoutRecorder.result(from: d)
        let finished = r.finish()
        #expect(fromDraft.distanceMeters == finished.distanceMeters)
        #expect(fromDraft.distanceMeters > 800)
        #expect(fromDraft.route == finished.route)
        #expect(fromDraft.segments == finished.segments)
        #expect(fromDraft.steps == finished.steps)
        #expect(abs(fromDraft.movingSeconds - finished.movingSeconds) < 0.5)
        #expect(fromDraft.start == finished.start)
    }

    @Test func encodeAndWriteTwoHours() throws {
        let store = tempStore()
        let d = sampleDraft(points: 7_200)
        try store.saveNow(d) // warm up
        let clock = ContinuousClock()
        let elapsed = try clock.measure { try store.saveNow(d) }
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("Draft encode+write for 7,200 points: \(ms) ms")
        #expect(store.load()?.points.count == 7_200)
        // Runs off the main thread in the app; this only guards against a pathological slowdown.
        #expect(ms < 1_000)
        store.clear()
    }
}
