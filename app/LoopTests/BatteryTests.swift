import Testing
import Foundation
@testable import Loop

/// Counts calls so tests can see when GPS turns on and off.
private final class CountingSource: LocationSource, MotionSource {
    var fixesCalls = 0, stopCalls = 0, activityCalls = 0, stopActivityCalls = 0, pedometerCalls = 0
    func fixes() -> AsyncStream<LocationFix> { fixesCalls += 1; return AsyncStream { _ in } }
    func activities() -> AsyncStream<MotionSample> { activityCalls += 1; return AsyncStream { _ in } }
    func pedometer(from start: Date) -> AsyncStream<PedometerSample> { pedometerCalls += 1; return AsyncStream { _ in } }
    func stopActivities() { stopActivityCalls += 1 }
    func stop() { stopCalls += 1 }
}

private func tempLog() -> PowerLog {
    PowerLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("power-\(UUID().uuidString).jsonl"))
}

@MainActor
struct PausedGPSTests {
    /// 1000x virtual clock: 0.25 s of real time is over 3 virtual minutes.
    private func fast() -> RecordingClock { RecordingClock(scale: 1000) }

    @Test func pauseTurnsGPSOffAfterThreeMinutesAndResumeRestartsIt() async throws {
        let loc = CountingSource(), mot = CountingSource()
        let log = tempLog()
        let r = WorkoutRecorder(location: loc, motion: mot, clock: fast())
        r.powerLog = log
        r.start(kind: .run)
        #expect(loc.fixesCalls == 1 && r.gpsOn)
        r.pause()
        r.checkPauseTimeout()
        #expect(loc.stopCalls == 0, "GPS stays on right after pausing")
        try await Task.sleep(for: .milliseconds(250))
        r.checkPauseTimeout()
        #expect(loc.stopCalls == 1)
        #expect(mot.stopActivityCalls == 1)
        #expect(!r.gpsOn)
        r.resume()
        #expect(loc.fixesCalls == 2 && mot.activityCalls == 2)
        #expect(mot.pedometerCalls == 1, "pedometer kept running through the pause")
        _ = r.finish()
        #expect(log.events().map(\.kind) == [.gpsOn, .gpsOff, .gpsOn, .gpsOff])
        #expect(log.events().map(\.reason) == ["recording start", "pause timeout", "resume", "finish"])
        log.clear()
    }

    @Test func shortPauseNeverStopsGPS() {
        let loc = CountingSource(), mot = CountingSource()
        let r = WorkoutRecorder(location: loc, motion: mot, clock: RecordingClock())
        r.start(kind: .walk)
        r.pause(); r.checkPauseTimeout(); r.resume()
        r.pause(); r.checkPauseTimeout(); r.resume()
        #expect(loc.stopCalls == 0 && loc.fixesCalls == 1)
        _ = r.finish()
    }

    @Test func finishWhilePausedWithGPSOff() async throws {
        let loc = CountingSource(), mot = CountingSource()
        let log = tempLog()
        let r = WorkoutRecorder(location: loc, motion: mot, clock: fast())
        r.powerLog = log
        r.start(kind: .run)
        r.pause()
        try await Task.sleep(for: .milliseconds(250))
        r.checkPauseTimeout()
        let result = r.finish()
        #expect(r.state == .finished)
        #expect(result.end >= result.start)
        // Finishing from a pause does not turn GPS back on.
        #expect(log.events().map(\.kind) == [.gpsOn, .gpsOff])
        #expect(loc.fixesCalls == 1)
        log.clear()
    }

    @Test func restorePausedKeepsGPSOffUntilResume() {
        let loc = CountingSource(), mot = CountingSource()
        let start = Date().addingTimeInterval(-600)
        let d = RecordingDraft(kind: .run, startDate: start, pausedTotal: 0, pauseStarted: start.addingTimeInterval(300),
                               wasPaused: true, savedAt: start.addingTimeInterval(320), points: [], modes: [],
                               motionSamples: [], pedo: [], cum: 0)
        let r = WorkoutRecorder.restore(d, location: loc, motion: mot, clock: RecordingClock(), paused: true, gap: 0)
        #expect(r.state == .paused)
        #expect(loc.fixesCalls == 0 && mot.activityCalls == 0 && mot.pedometerCalls == 0)
        r.resume()
        #expect(loc.fixesCalls == 1 && mot.activityCalls == 1 && mot.pedometerCalls == 1)
        _ = r.finish()
    }

    @Test func restoreNotPausedStartsGPS() {
        let loc = CountingSource(), mot = CountingSource()
        let start = Date().addingTimeInterval(-60)
        let d = RecordingDraft(kind: .run, startDate: start, pausedTotal: 0, pauseStarted: nil, wasPaused: false,
                               savedAt: start.addingTimeInterval(50), points: [], modes: [], motionSamples: [], pedo: [], cum: 0)
        let r = WorkoutRecorder.restore(d, location: loc, motion: mot, clock: RecordingClock(), paused: false, gap: 10)
        #expect(r.state == .recording && loc.fixesCalls == 1)
        _ = r.finish()
    }
}

struct PowerLogTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func e(_ k: PowerLog.Kind, _ s: Double) -> PowerLog.Event { .init(time: t0.addingTimeInterval(s), kind: k, reason: "") }

    @Test func openIntervalRunsToNow() {
        let ev = [e(.gpsOn, 0), e(.gpsOff, 600), e(.gpsOn, 1000)]
        let total = PowerLog.gpsIntervals(ev, now: t0.addingTimeInterval(1300)).reduce(0) { $0 + $1.duration }
        #expect(total == 900)
    }

    @Test func launchClosesAnOpenInterval() {
        // Killed with GPS on, relaunched later: GPS ended no later than the relaunch.
        let ev = [e(.gpsOn, 0), e(.launch, 300), e(.gpsOn, 1000), e(.gpsOn, 1100), e(.gpsOff, 1200)]
        let iv = PowerLog.gpsIntervals(ev, now: t0.addingTimeInterval(5000))
        #expect(iv.map(\.duration) == [300, 200])
    }

    @Test func dayBoundariesSplitIntervals() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.startOfDay(for: t0).addingTimeInterval(86400)
        let ev = [PowerLog.Event(time: midnight.addingTimeInterval(-600), kind: .gpsOn, reason: ""),
                  PowerLog.Event(time: midnight.addingTimeInterval(900), kind: .gpsOff, reason: "")]
        let now = midnight.addingTimeInterval(3600)
        #expect(PowerLog.gpsSeconds(ev, on: midnight.addingTimeInterval(-1), now: now, calendar: cal) == 600)
        #expect(PowerLog.gpsSeconds(ev, on: midnight, now: now, calendar: cal) == 900)
    }

    @Test func fileRoundTripAndPrune() {
        let log = tempLog()
        let now = Date()
        log.log(.gpsOn, reason: "old", at: now.addingTimeInterval(-15 * 86400))
        log.log(.gpsOn, reason: "recording start", at: now)
        log.log(.gpsOff, reason: "finish", at: now)
        #expect(log.events().count == 3)
        log.prune(now: now)
        #expect(log.events().map(\.reason) == ["recording start", "finish"])
        log.clear()
    }
}

private final class BundleToken {}

struct MetricsParserTests {
    @Test func parsesSyntheticFixture() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "metric-payload-synthetic", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let diag = Data("""
        {"timeStampBegin":"2026-11-04 00:00:00 +0000","timeStampEnd":"2026-11-04 23:59:00 +0000",
         "crashDiagnostics":[{}],"hangDiagnostics":[{},{}],"cpuExceptionDiagnostics":[{}]}
        """.utf8)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let days = MetricsStore.summarize(metrics: [data], diagnostics: [diag], calendar: cal)
        #expect(days.count == 1)
        let d = try #require(days.first)
        #expect(d.foreground == 2700)
        #expect(d.background == 12540)
        #expect(d.backgroundLocation == 7200)
        #expect(d.cpu == 312)
        #expect(d.locationNavigation == 6900)
        #expect(d.locationBest == 300)
        #expect(d.networkUp == 25_000)
        #expect(d.networkDown == 1_500_000)
        #expect(d.crashes == 1 && d.hangs == 2 && d.cpuExceptions == 1)
    }

    @Test func unitsAndStorageDedupe() throws {
        #expect(MetricsStore.seconds("2 min") == 120)
        #expect(MetricsStore.seconds(NSNumber(value: 5)) == 5)
        #expect(MetricsStore.bytes("3 MB") == 3_000_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-\(UUID().uuidString)")
        let store = MetricsStore(dir: dir)
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "metric-payload-synthetic", withExtension: "json"))
        let data = try Data(contentsOf: url)
        store.ingest(metrics: [data])
        store.ingest(metrics: [data])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
        #expect(store.days().first?.background == 12540)
        try? FileManager.default.removeItem(at: dir)
    }
}
