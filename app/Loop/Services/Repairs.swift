import Foundation
import SwiftData

/// One-time fixes to stored workouts.
@MainActor
enum Repairs {
    // MARK: GPS-less auto pieces: one walk saved as several 10-minute pieces with no route.

    struct Window: Sendable {
        var name: String
        /// Set once the pieces are replaced by the motion record's walk.
        var repairKey: String
        /// Set once Loop's own Health workouts in the window that nothing references are gone.
        var sweepKey: String
        /// Pieces start inside [from, to]; the motion record is rescanned over [from, scanTo].
        var from: Date
        var to: Date
        var scanTo: Date
    }

    static let windows: [Window] = [
        Window(name: "8 Nov night", repairKey: "repair8NovDone", sweepKey: "healthSweep8NovDone",
               from: Date(timeIntervalSince1970: 1_794_159_000),     // 2026-11-08T17:30Z
               to: Date(timeIntervalSince1970: 1_794_169_800),       // 2026-11-08T20:30Z
               scanTo: Date(timeIntervalSince1970: 1_794_171_600)),  // 2026-11-08T21:00Z
        Window(name: "9 Nov", repairKey: "repair9NovDone", sweepKey: "healthSweep9NovDone",
               from: Date(timeIntervalSince1970: 1_794_229_200),     // 2026-11-09T13:00Z
               to: Date(timeIntervalSince1970: 1_794_250_800),       // 2026-11-09T19:00Z
               scanTo: Date(timeIntervalSince1970: 1_794_257_100)),  // 2026-11-09T20:45Z
    ]

    /// Health calls, injectable for tests.
    struct HealthOps {
        /// True when the workout is gone.
        var delete: (UUID) async -> Bool
        /// UUIDs of Loop's own Health workouts overlapping a range; nil when the query failed.
        var loopWorkouts: (Date, Date) async -> [UUID]?

        @MainActor static let live = HealthOps(delete: { await HealthService.shared.delete(id: $0) },
                                               loopWorkouts: { await HealthService.shared.loopWorkoutIDs(from: $0, to: $1) })
    }

    /// Recorded workouts (any kind) with no route that started inside the window. Pure.
    static func pieces(_ all: [Workout], in w: Window) -> [Workout] {
        all.filter { $0.source == "recorded" && !$0.isCheckIn && $0.routeData == nil
            && $0.startDate >= w.from && $0.startDate <= w.to }
    }

    /// Every window: repair, then sweep. Marks this launch's attempt done whatever happens.
    static func runAll(_ ctx: ModelContext, history: MotionHistory, defaults: UserDefaults = .standard,
                       log: PowerLog? = PowerLog.shared, health: HealthOps = .live) async {
        defer { repairsAttempted = true }
        for w in windows {
            await repair(w, ctx, history: history, defaults: defaults, log: log, health: health)
            await sweep(w, ctx, defaults: defaults, log: log, health: health)
        }
    }

    /// Replaces the pieces with what the motion record shows. A piece goes only once its Health copy is
    /// gone; any failed Health delete keeps it, skips the rescan and leaves the flag for the next launch.
    /// Nothing is deleted when the motion record is unavailable or empty.
    @discardableResult
    static func repair(_ w: Window, _ ctx: ModelContext, history: MotionHistory, defaults: UserDefaults,
                       log: PowerLog?, health: HealthOps) async -> Bool {
        guard !defaults.bool(forKey: w.repairKey) else { return false }
        guard history.provider.isAuthorized,
              !(await history.provider.activities(from: w.from, to: w.scanTo)).isEmpty else { return false }
        var removed = 0, healthDeleted = 0, healthFailed = 0
        for p in pieces((try? ctx.fetch(FetchDescriptor<Workout>())) ?? [], in: w) {
            if let id = p.healthKitID {
                guard await health.delete(id) else { healthFailed += 1; continue }
                healthDeleted += 1
            }
            ctx.delete(p)
            removed += 1
        }
        try? ctx.save()
        guard healthFailed == 0 else {
            log?.log(.repair, reason: "\(w.name): removed \(removed), healthDeleted \(healthDeleted), healthFailed \(healthFailed), retry next launch")
            return false
        }
        history.dismissed?.remove(within: w.from, w.scanTo)
        guard let added = await history.rescan(ctx, from: w.from, to: w.scanTo) else { return false }
        defaults.set(true, forKey: w.repairKey)
        log?.log(.repair, reason: "\(w.name): removed \(removed), healthDeleted \(healthDeleted), healthFailed 0, added \(added)")
        return true
    }

    /// Deletes Loop's own Health workouts overlapping the window that no stored workout references
    /// (a piece whose earlier delete failed). Runs once, after the window's repair is done.
    @discardableResult
    static func sweep(_ w: Window, _ ctx: ModelContext, defaults: UserDefaults, log: PowerLog?, health: HealthOps) async -> Bool {
        guard defaults.bool(forKey: w.repairKey), !defaults.bool(forKey: w.sweepKey) else { return false }
        guard let ids = await health.loopWorkouts(w.from, w.scanTo) else { return false }
        let referenced = Set(((try? ctx.fetch(FetchDescriptor<Workout>())) ?? []).compactMap(\.healthKitID))
        var swept = 0, failed = 0
        for id in ids where !referenced.contains(id) {
            if await health.delete(id) { swept += 1 } else { failed += 1 }
        }
        log?.log(.repair, reason: "\(w.name) Health sweep: swept \(swept), healthFailed \(failed)")
        guard failed == 0 else { return false }
        defaults.set(true, forKey: w.sweepKey)
        return true
    }

    // MARK: Health retry

    /// Set once this launch's repair attempts have finished (whatever their outcome). The Health retry
    /// waits for it, so it never writes the pieces a repair is about to delete.
    static var repairsAttempted = false

    /// Recorded GPS workouts from the last 7 days that never reached Health. Pure.
    static func healthRetryCandidates(_ all: [Workout], now: Date, healthOn: Bool) -> [Workout] {
        guard healthOn else { return [] }
        let from = now.addingTimeInterval(-7 * 86400)
        let pieces = Set(windows.flatMap { Self.pieces(all, in: $0) }.map(\.id))
        return all.filter { !pieces.contains($0.id) && $0.source == "recorded" && !$0.isCheckIn && $0.healthKitID == nil
            && $0.kind.isGPS && $0.startDate >= from }
    }

    private static var retrying = false

    /// Writes missed workouts to Health (a save from a locked phone fails). Once per activation.
    static func retryHealth(_ ctx: ModelContext, now: Date = Date()) async {
        guard repairsAttempted, !retrying else { return }
        retrying = true; defer { retrying = false }
        let on = (UserDefaults.standard.object(forKey: "saveToHealth") as? Bool ?? true) && LaunchOptions.healthAllowed
        let todo = healthRetryCandidates((try? ctx.fetch(FetchDescriptor<Workout>())) ?? [], now: now, healthOn: on)
        for w in todo {
            if let id = await HealthService.shared.save(kind: w.kind, start: w.startDate, end: w.endDate,
                                                        distanceMeters: w.distanceMeters, route: w.route) {
                // Deleted meanwhile: take the Health copy back out rather than orphan it.
                if w.isDeleted || w.modelContext == nil { await HealthService.shared.delete(id: id); continue }
                w.healthKitID = id
                try? ctx.save()
            }
        }
    }
}
