import Testing
import Foundation
import SwiftData
@testable import Loop

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Builds samples from (minutes, kind, confidence) legs starting at t0.
private func legs(_ l: [(Double, ActivityHistorySample.Kind, MotionConfidence)]) -> (samples: [ActivityHistorySample], end: Date) {
    var t = t0
    var out: [ActivityHistorySample] = []
    for (m, k, c) in l {
        out.append(.init(start: t, kind: k, confidence: c))
        t = t.addingTimeInterval(m * 60)
    }
    return (out, t)
}

struct BoutDetectorTests {
    /// Ends every case with a long stationary stretch so nothing is still open.
    private func run(_ l: [(Double, ActivityHistorySample.Kind, MotionConfidence)]) -> BoutDetector.Result {
        let (s, end) = legs(l + [(60, .stationary, .high)])
        return BoutDetector.detect(s, now: end)
    }

    @Test func walkWithShortGapIsOneWalk() {
        let r = run([(15, .walking, .high), (1.5, .stationary, .high), (13.5, .walking, .medium)])
        #expect(r.bouts.count == 1)
        let b = r.bouts[0]
        #expect(b.kind == .walk)
        #expect(abs(b.movingSeconds - 28.5 * 60) < 1)
        #expect(b.start == t0 && b.end == t0.addingTimeInterval(30 * 60))
    }

    @Test func shortWalkGivesNothing() {
        #expect(run([(4, .walking, .high)]).bouts.isEmpty)
    }

    @Test func walkThenRunIsARun() {
        let r = run([(20, .walking, .high), (8, .running, .high)])
        #expect(r.bouts.map(\.kind) == [.run])
        #expect(r.bouts[0].runningSeconds == 8 * 60)
    }

    @Test func automotiveSplitsAndShortTailDropped() {
        let r = run([(15, .walking, .high), (10, .automotive, .high), (5, .walking, .high)])
        #expect(r.bouts.count == 1)
        #expect(r.bouts[0].kind == .walk && r.bouts[0].movingSeconds == 15 * 60)
    }

    @Test func openBoutIsNotEmitted() {
        let (s, end) = legs([(20, .walking, .high), (1, .stationary, .high)])
        let r = BoutDetector.detect(s, now: end)
        #expect(r.bouts.isEmpty)
        #expect(r.openStart == t0)
        // Still walking right now: also open.
        let (s2, end2) = legs([(20, .walking, .high)])
        #expect(BoutDetector.detect(s2, now: end2).openStart == t0)
    }

    @Test func lowConfidenceOnlyGivesNothing() {
        #expect(run([(30, .walking, .low), (10, .running, .low)]).bouts.isEmpty)
    }

    @Test func cyclingIsARide() {
        let r = run([(15, .cycling, .high)])
        #expect(r.bouts.map(\.kind) == [.ride])
    }

    @Test func longGapSplits() {
        let r = run([(12, .walking, .high), (5, .stationary, .high), (12, .walking, .high)])
        #expect(r.bouts.count == 2)
    }

    @Test func lowConfidenceContinuesABout() {
        let r = run([(5, .walking, .high), (6, .walking, .low)])
        #expect(r.bouts.count == 1 && r.bouts[0].movingSeconds == 11 * 60)
    }
}

private final class StubHistory: MotionHistoryProvider {
    var samples: [ActivityHistorySample]
    var authorized = true
    var queries: [(Date, Date)] = []
    init(_ s: [ActivityHistorySample]) { samples = s }
    var isAuthorized: Bool { authorized }
    func activities(from: Date, to: Date) async -> [ActivityHistorySample] {
        queries.append((from, to))
        return samples
    }
    func pedometer(from: Date, to: Date) async -> (steps: Int, distance: Double?, floors: Int?)? {
        (2000, nil, 2)
    }
}

@MainActor
struct MotionScanTests {
    let container: ModelContainer
    let ctx: ModelContext
    let defaults: UserDefaults
    let dismissed: DismissedStore

    init() throws {
        container = try ModelContainer(for: Workout.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = container.mainContext
        defaults = UserDefaults(suiteName: "scan-\(UUID().uuidString)")!
        dismissed = DismissedStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("dismissed-\(UUID().uuidString).json"))
    }

    private func all() -> [Workout] { (try? ctx.fetch(FetchDescriptor<Workout>())) ?? [] }

    /// A 20 minute walk and a 15 minute ride, ending an hour before `now`.
    private func history() -> (StubHistory, Date) {
        let (s, end) = legs([(20, .walking, .high), (30, .stationary, .high), (15, .cycling, .high), (60, .stationary, .high)])
        return (StubHistory(s), end)
    }

    @Test func addsDetectedWorkouts() async {
        let (h, now) = history()
        let m = MotionHistory(provider: h, dismissed: dismissed, defaults: defaults)
        #expect(await m.scan(ctx, now: now) == 2)
        let ws = all().sorted { $0.startDate < $1.startDate }
        #expect(ws.map(\.kind) == [.walk, .ride])
        #expect(ws.allSatisfy { $0.isDetected && $0.route.isEmpty && $0.healthKitID == nil })
        #expect(ws[0].distanceMeters == 0, "nil pedometer distance is stored as 0")
        #expect(ws[0].steps == 2000 && ws[0].floors == 2)
        #expect(ws[0].nameReason == MotionHistory.reason)
        #expect(!ws[0].name.isEmpty)
    }

    @Test func scanTwiceAddsNothingNew() async {
        let (h, now) = history()
        let m = MotionHistory(provider: h, dismissed: dismissed, defaults: defaults)
        await m.scan(ctx, now: now)
        #expect(await m.scan(ctx, now: now) == 0)
        // Even without the cursor, overlap keeps it idempotent.
        let m2 = MotionHistory(provider: h, dismissed: dismissed, defaults: defaults)
        m2.useCursor = false
        #expect(await m2.scan(ctx, now: now.addingTimeInterval(600)) == 0)
        #expect(all().count == 2)
    }

    @Test func overlappingRecordedWorkoutWins() async {
        let (h, now) = history()
        let rec = Workout(kind: .walk, startDate: t0.addingTimeInterval(300), endDate: t0.addingTimeInterval(900),
                          movingSeconds: 600, distanceMeters: 800)
        ctx.insert(rec)
        let m = MotionHistory(provider: h, dismissed: dismissed, defaults: defaults)
        #expect(await m.scan(ctx, now: now) == 1)
        #expect(all().filter(\.isDetected).map(\.kind) == [.ride])
    }

    @Test func dismissedIsNeverAddedBack() async {
        let (h, now) = history()
        let m = MotionHistory(provider: h, dismissed: dismissed, defaults: defaults)
        m.useCursor = false
        await m.scan(ctx, now: now)
        let walk = all().first { $0.kind == .walk }!
        m.dismiss(walk, in: ctx)
        #expect(await m.scan(ctx, now: now) == 0)
        #expect(all().map(\.kind) == [.ride])
        dismissed.clear()
    }

    @Test func openBoutIsPickedUpLater() async {
        // Walking now: nothing yet, and the cursor waits at the walk's start.
        let (s, end) = legs([(20, .walking, .high)])
        let h = StubHistory(s)
        let m = MotionHistory(provider: h, dismissed: dismissed, defaults: defaults)
        #expect(await m.scan(ctx, now: end) == 0)
        #expect(defaults.object(forKey: MotionHistory.cursorKey) as? Date == t0)
        h.samples.append(.init(start: end, kind: .stationary, confidence: .high))
        #expect(await m.scan(ctx, now: end.addingTimeInterval(600)) == 1)
        #expect(h.queries.last?.0 == t0)
    }

    @Test func notAuthorizedOrOffDoesNothing() async {
        let (h, now) = history()
        h.authorized = false
        let m = MotionHistory(provider: h, dismissed: dismissed, defaults: defaults)
        #expect(await m.scanIfDue(ctx, now: now) == 0)
        h.authorized = true
        defaults.set(false, forKey: MotionHistory.enabledKey)
        #expect(await m.scanIfDue(ctx, now: now) == 0)
        #expect(h.queries.isEmpty)
    }

    @Test func savingARecordingRemovesOverlappingDetected() async {
        let (h, now) = history()
        await MotionHistory(provider: h, dismissed: dismissed, defaults: defaults).scan(ctx, now: now)
        let r = RecordingResult(kind: .walk, start: t0.addingTimeInterval(120), end: t0.addingTimeInterval(1500),
                                movingSeconds: 1380, distanceMeters: 1800, steps: nil, route: [], segments: [])
        await WorkoutStore.save(r, in: ctx, usePlaces: false, saveToHealth: false)
        #expect(all().filter(\.isDetected).map(\.kind) == [.ride])
        #expect(all().filter { !$0.isDetected }.count == 1)
    }

    @Test func capLeavesTheRestForTheNextScan() async {
        // Five 12 minute walks, each followed by 10 minutes standing still.
        var l: [(Double, ActivityHistorySample.Kind, MotionConfidence)] = []
        for _ in 0..<5 { l += [(12, .walking, .high), (10, .stationary, .high)] }
        let (s, end) = legs(l + [(60, .stationary, .high)])
        let m = MotionHistory(provider: StubHistory(s), dismissed: dismissed, defaults: defaults)
        m.maxInserts = 3
        #expect(await m.scan(ctx, now: end) == 3)
        #expect(await m.scan(ctx, now: end) == 2)
        #expect(await m.scan(ctx, now: end) == 0)
        let starts = all().map(\.startDate).sorted()
        #expect(starts == (0..<5).map { t0.addingTimeInterval(Double($0) * 22 * 60) })
    }
}
