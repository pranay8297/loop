import Foundation
import SwiftData

/// One-time fixes to stored workouts.
@MainActor
enum Repairs {
    // MARK: 8 Nov night: one walk saved as several GPS-less 10-minute pieces.

    static let night8NovKey = "repair8NovDone"
    static let night8NovFrom = Date(timeIntervalSince1970: 1_794_159_000)   // 2026-11-08T17:30:00Z
    static let night8NovTo = Date(timeIntervalSince1970: 1_794_169_800)     // 2026-11-08T20:30:00Z
    static let night8NovScanTo = Date(timeIntervalSince1970: 1_794_171_600) // 2026-11-08T21:00:00Z

    /// Recorded walks with no route that started inside the window. Pure.
    static func night8NovPieces(_ all: [Workout]) -> [Workout] {
        all.filter { $0.source == "recorded" && !$0.isCheckIn && $0.routeData == nil
            && $0.startDate >= night8NovFrom && $0.startDate <= night8NovTo }
    }

    /// Replaces the pieces with what the motion record shows. Runs once; the flag is set only after a
    /// successful rescan, and nothing is deleted when the motion record is unavailable or empty.
    @discardableResult
    static func night8NovOnce(_ ctx: ModelContext, history: MotionHistory, defaults: UserDefaults = .standard,
                              log: PowerLog? = PowerLog.shared,
                              deleteHealth: (UUID) async -> Void = { await HealthService.shared.delete(id: $0) }) async -> Bool {
        defer { night8NovAttempted = true }
        guard !defaults.bool(forKey: night8NovKey) else { return false }
        guard history.provider.isAuthorized,
              !(await history.provider.activities(from: night8NovFrom, to: night8NovScanTo)).isEmpty else { return false }
        let pieces = night8NovPieces((try? ctx.fetch(FetchDescriptor<Workout>())) ?? [])
        for w in pieces {
            if let id = w.healthKitID { await deleteHealth(id) }
            ctx.delete(w)
        }
        try? ctx.save()
        let undismissed = history.dismissed?.remove(within: night8NovFrom, night8NovScanTo) ?? 0
        guard let added = await history.rescan(ctx, from: night8NovFrom, to: night8NovScanTo) else { return false }
        defaults.set(true, forKey: night8NovKey)
        log?.log(.repair, reason: "8 Nov night: removed \(pieces.count), added \(added), undismissed \(undismissed)")
        return true
    }

    // MARK: Health retry

    /// Set once this launch's 8 Nov repair attempt has finished (whatever its outcome). The Health
    /// retry waits for it, so it never writes the pieces the repair is about to delete.
    static var night8NovAttempted = false

    /// Recorded GPS workouts from the last 7 days that never reached Health. Pure.
    static func healthRetryCandidates(_ all: [Workout], now: Date, healthOn: Bool) -> [Workout] {
        guard healthOn else { return [] }
        let from = now.addingTimeInterval(-7 * 86400)
        let pieces = Set(night8NovPieces(all).map(\.id))
        return all.filter { !pieces.contains($0.id) && $0.source == "recorded" && !$0.isCheckIn && $0.healthKitID == nil
            && $0.kind.isGPS && $0.startDate >= from }
    }

    private static var retrying = false

    /// Writes missed workouts to Health (a save from a locked phone fails). Once per activation.
    static func retryHealth(_ ctx: ModelContext, now: Date = Date()) async {
        guard night8NovAttempted, !retrying else { return }
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
