import Foundation
import CoreMotion
import SwiftData

/// Reads the motion chip's history. Live uses Core Motion; tests and DEBUG use fakes.
protocol MotionHistoryProvider: AnyObject {
    var isAuthorized: Bool { get }
    func activities(from: Date, to: Date) async -> [ActivityHistorySample]
    func pedometer(from: Date, to: Date) async -> (steps: Int, distance: Double?, floors: Int?)?
}

final class LiveMotionHistory: MotionHistoryProvider {
    private let activity = CMMotionActivityManager()
    private let pedo = CMPedometer()

    var isAuthorized: Bool {
        CMMotionActivityManager.isActivityAvailable() && CMMotionActivityManager.authorizationStatus() == .authorized
    }

    func activities(from: Date, to: Date) async -> [ActivityHistorySample] {
        await withCheckedContinuation { c in
            activity.queryActivityStarting(from: from, to: to, to: .main) { list, _ in
                c.resume(returning: (list ?? []).map(Self.sample))
            }
        }
    }

    func pedometer(from: Date, to: Date) async -> (steps: Int, distance: Double?, floors: Int?)? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return await withCheckedContinuation { c in
            pedo.queryPedometerData(from: from, to: to) { d, _ in
                guard let d else { c.resume(returning: nil); return }
                c.resume(returning: (d.numberOfSteps.intValue, d.distance?.doubleValue, d.floorsAscended?.intValue))
            }
        }
    }

    static func sample(_ a: CMMotionActivity) -> ActivityHistorySample {
        let kind: ActivityHistorySample.Kind =
            a.running ? .running : a.cycling ? .cycling : a.walking ? .walking
            : a.automotive ? .automotive : a.stationary ? .stationary : .unknown
        let conf: MotionConfidence = switch a.confidence {
        case .high: .high
        case .medium: .medium
        default: .low
        }
        return ActivityHistorySample(start: a.startDate, kind: kind, confidence: conf)
    }

    /// Shows the system Motion & Fitness prompt by asking for a minute of history.
    static func requestAccess(_ done: @escaping @MainActor () -> Void) {
        let m = CMMotionActivityManager()
        m.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, _ in
            _ = m
            MainActor.assumeIsolated { done() }
        }
    }
}

/// Time ranges the user said were not workouts. JSON in Application Support, kept 30 days.
final class DismissedStore: @unchecked Sendable {
    struct Range: Codable, Equatable { var start: Date; var end: Date }
    static let keepDays: Double = 30
    static let shared: DismissedStore? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return DismissedStore(url: dir.appendingPathComponent("dismissed-workouts.json"))
    }()

    let url: URL
    init(url: URL) { self.url = url }

    func load(now: Date = Date()) -> [Range] {
        guard let d = try? Data(contentsOf: url), let all = try? JSONDecoder().decode([Range].self, from: d) else { return [] }
        return all.filter { $0.end > now.addingTimeInterval(-Self.keepDays * 86400) }
    }

    func add(start: Date, end: Date, now: Date = Date()) {
        var all = load(now: now)
        all.append(Range(start: start, end: end))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    func clear() { try? FileManager.default.removeItem(at: url) }

    /// Drops ranges that lie inside [start, end]. Returns how many went.
    @discardableResult
    func remove(within start: Date, _ end: Date, now: Date = Date()) -> Int {
        let all = load(now: now)
        let kept = all.filter { !($0.start >= start && $0.end <= end) }
        guard kept.count != all.count else { return 0 }
        try? JSONEncoder().encode(kept).write(to: url, options: .atomic)
        return all.count - kept.count
    }
}

/// Adds walks, runs and rides from the motion record as workouts without a route.
/// Never turns GPS on and never asks for permission itself.
@MainActor
final class MotionHistory {
    static let window: TimeInterval = 7 * 86400
    static let minOverlap: TimeInterval = 60
    static let defaultMaxInserts = 50
    static let minInterval: TimeInterval = 300
    static let reason = "Picked up from your iPhone's motion record. GPS was off, so there's no route."
    static let enabledKey = "autoLogWalks"
    static let cursorKey = "motionScanEnd"

    let provider: MotionHistoryProvider
    let dismissed: DismissedStore?
    let defaults: UserDefaults
    /// False for DEBUG fakes: always scan the whole window so dismissals are what keeps rows out.
    var useCursor = true
    var throttle = true
    /// Most workouts one scan adds; the rest wait for the next scan.
    var maxInserts = MotionHistory.defaultMaxInserts
    private var lastRun: Date?
    private var running = false

    init(provider: MotionHistoryProvider, dismissed: DismissedStore?, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.dismissed = dismissed
        self.defaults = defaults
    }

    static let shared: MotionHistory = {
        #if DEBUG
        if LaunchOptions.args.contains("-LoopFakeMotionHistory") {
            let m = MotionHistory(provider: FakeMotionHistory(), dismissed: DismissedStore.shared)
            m.useCursor = false
            m.throttle = false
            if LaunchOptions.args.contains("-LoopClearDismissed") { DismissedStore.shared?.clear() }
            return m
        }
        #endif
        return MotionHistory(provider: LiveMotionHistory(), dismissed: DismissedStore.shared)
    }()

    var enabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Scans if allowed and not done in the last 5 minutes. Returns how many workouts were added.
    @discardableResult
    func scanIfDue(_ ctx: ModelContext, now: Date = Date()) async -> Int {
        guard enabled, provider.isAuthorized, !running else { return 0 }
        if throttle, let l = lastRun, now.timeIntervalSince(l) < Self.minInterval { return 0 }
        lastRun = now
        return await scan(ctx, now: now)
    }

    /// One pass over the motion record since the last scan (at most 7 days back).
    @discardableResult
    func scan(_ ctx: ModelContext, now: Date = Date()) async -> Int {
        running = true; defer { running = false }
        var from = now.addingTimeInterval(-Self.window)
        if useCursor, let c = defaults.object(forKey: Self.cursorKey) as? Date, c > from { from = min(c, now) }
        let samples = await provider.activities(from: from, to: now)
        let result = BoutDetector.detect(samples, now: now)

        let existing = ((try? ctx.fetch(FetchDescriptor<Workout>())) ?? []).map { ($0.startDate, $0.endDate) }
        let skip = existing + (dismissed?.load(now: now) ?? []).map { ($0.start, $0.end) }
        var added = 0
        var cursor = from
        var capped = false
        for b in result.bouts {
            if skip.contains(where: { Self.overlap(b.start, b.end, $0.0, $0.1) >= Self.minOverlap }) {
                cursor = max(cursor, b.end); continue
            }
            // Full: stop before this bout so the next scan picks it up.
            guard added < maxInserts else { capped = true; cursor = max(from, min(cursor, b.start)); break }
            cursor = max(cursor, b.end)
            let p = await provider.pedometer(from: b.start, to: b.end)
            let w = Workout(kind: b.kind, startDate: b.start, endDate: b.end, movingSeconds: b.movingSeconds,
                            distanceMeters: b.kind == .ride ? 0 : (p?.distance ?? 0), steps: p?.steps)
            w.source = "motion"
            w.floors = p?.floors
            let input = NamingInput(start: b.start, timeZone: .current, latitude: nil, longitude: nil, place: nil,
                                    shape: .pointToPoint, kind: b.kind, hasWalkSegments: false, highlights: [])
            w.name = await WorkoutStore.namer.name(for: input).name
            w.nameReason = Self.reason
            ctx.insert(w)
            added += 1
        }
        if let open = result.openStart { cursor = capped ? min(cursor, open) : open }
        else if result.bouts.isEmpty { cursor = max(from, now.addingTimeInterval(-BoutDetector.openWithin)) }
        if useCursor { defaults.set(cursor, forKey: Self.cursorKey) }
        if added > 0 { try? ctx.save() }
        return added
    }

    /// Adds the bouts in a fixed window, like a scan but ignoring the cursor and leaving it alone.
    /// Returns how many were added, or nil when the motion record is unavailable or empty there.
    func rescan(_ ctx: ModelContext, from: Date, to: Date) async -> Int? {
        guard provider.isAuthorized else { return nil }
        let samples = await provider.activities(from: from, to: to)
        guard !samples.isEmpty else { return nil }
        let bouts = BoutDetector.detect(samples, now: to).bouts
        let existing = ((try? ctx.fetch(FetchDescriptor<Workout>())) ?? []).map { ($0.startDate, $0.endDate) }
        let skip = existing + (dismissed?.load() ?? []).map { ($0.start, $0.end) }
        var added = 0
        for b in bouts where !skip.contains(where: { Self.overlap(b.start, b.end, $0.0, $0.1) >= Self.minOverlap }) {
            let p = await provider.pedometer(from: b.start, to: b.end)
            let w = Workout(kind: b.kind, startDate: b.start, endDate: b.end, movingSeconds: b.movingSeconds,
                            distanceMeters: b.kind == .ride ? 0 : (p?.distance ?? 0), steps: p?.steps)
            w.source = "motion"
            w.floors = p?.floors
            let input = NamingInput(start: b.start, timeZone: .current, latitude: nil, longitude: nil, place: nil,
                                    shape: .pointToPoint, kind: b.kind, hasWalkSegments: false, highlights: [])
            w.name = await WorkoutStore.namer.name(for: input).name
            w.nameReason = Self.reason
            ctx.insert(w)
            added += 1
        }
        try? ctx.save()
        return added
    }

    /// "Not a workout": deletes it and remembers its time so a scan never adds it back.
    func dismiss(_ w: Workout, in ctx: ModelContext) {
        dismissed?.add(start: w.startDate, end: w.endDate)
        ctx.delete(w)
        try? ctx.save()
    }

    static func overlap(_ a0: Date, _ a1: Date, _ b0: Date, _ b1: Date) -> TimeInterval {
        min(a1, b1).timeIntervalSince(max(a0, b0))
    }
}

#if DEBUG
/// Synthetic history for UI tests and screenshots (`-LoopFakeMotionHistory`): a walk this
/// morning, a run yesterday and a ride two days ago, placed relative to now.
final class FakeMotionHistory: MotionHistoryProvider {
    var isAuthorized: Bool { true }

    func activities(from: Date, to: Date) async -> [ActivityHistorySample] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: to)
        func at(_ dayOffset: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(byAdding: .minute, value: dayOffset * 1440 + h * 60 + m, to: today)!
        }
        // Today's walk ends at least 10 minutes before now.
        let walkEnd = min(at(0, 8, 0), to.addingTimeInterval(-600))
        let walkStart = walkEnd.addingTimeInterval(-24 * 60 - 10)
        let list: [ActivityHistorySample] = [
            .init(start: at(-2, 17, 0), kind: .cycling, confidence: .high),
            .init(start: at(-2, 17, 32), kind: .stationary, confidence: .high),
            .init(start: at(-1, 6, 30), kind: .walking, confidence: .high),
            .init(start: at(-1, 6, 35), kind: .running, confidence: .high),
            .init(start: at(-1, 7, 5), kind: .stationary, confidence: .high),
            // A short stroll that is not a workout (motion record view).
            .init(start: at(-1, 12, 0), kind: .walking, confidence: .high),
            .init(start: at(-1, 12, 5), kind: .stationary, confidence: .high),
            .init(start: walkStart, kind: .walking, confidence: .high),
            .init(start: walkEnd, kind: .stationary, confidence: .high),
        ]
        return list.filter { $0.start >= from.addingTimeInterval(-3600) && $0.start <= to }
    }

    func pedometer(from: Date, to: Date) async -> (steps: Int, distance: Double?, floors: Int?)? {
        let mins = to.timeIntervalSince(from) / 60
        return (Int(mins * 110), mins * 88, 3)
    }
}
#endif
