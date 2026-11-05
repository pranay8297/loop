import Foundation

/// One reading from the motion chip's history, like a `CMMotionActivity`.
struct ActivityHistorySample: Equatable, Sendable {
    enum Kind: String, Sendable { case walking, running, cycling, automotive, stationary, unknown }
    var start: Date
    var kind: Kind
    var confidence: MotionConfidence
}

/// A stretch of walking, running or riding found in motion history.
struct Bout: Equatable, Sendable {
    var kind: ActivityKind
    var start: Date
    var end: Date
    var movingSeconds: Double
    var runningSeconds: Double
}

/// Finds walks, runs and rides in motion history. Pure; all times are absolute Dates.
enum BoutDetector {
    static let bridgeGap: TimeInterval = 120
    static let openWithin: TimeInterval = 180
    static let minWalk: TimeInterval = 600
    static let minRun: TimeInterval = 300
    static let minRide: TimeInterval = 600
    static let runAtLeast: TimeInterval = 180
    static let runShare = 0.25

    struct Result: Equatable {
        var bouts: [Bout]
        /// Start of a bout that may still be going (moving within `openWithin` of now).
        var openStart: Date?
    }

    private enum Family { case foot, cycle }

    private struct Open {
        var family: Family
        var start: Date
        var lastEnd: Date
        var moving: Double = 0
        var running: Double = 0
    }

    static func detect(_ raw: [ActivityHistorySample], now: Date) -> Result {
        let s = raw.sorted { $0.start < $1.start }
        var out: [Bout] = []
        var cur: Open?

        func close() {
            guard let c = cur else { return }
            cur = nil
            if let b = bout(c) { out.append(b) }
        }

        for (i, x) in s.enumerated() {
            let end = i + 1 < s.count ? s[i + 1].start : now
            let dur = max(0, end.timeIntervalSince(x.start))
            guard dur > 0 else { continue }
            let fam: Family?
            switch x.kind {
            case .walking, .running: fam = .foot
            case .cycling: fam = .cycle
            case .automotive: close(); continue
            case .stationary, .unknown: fam = nil
            }
            guard let fam else { continue }
            // A long gap since the last movement ends the bout.
            if let c = cur, x.start.timeIntervalSince(c.lastEnd) > bridgeGap { close() }
            if let c = cur, c.family != fam {
                // A different kind of movement ends the bout; low confidence of it is ignored.
                guard x.confidence >= .medium else { continue }
                close()
            }
            if cur == nil {
                guard x.confidence >= .medium else { continue }
                cur = Open(family: fam, start: x.start, lastEnd: x.start)
            }
            cur!.moving += dur
            if x.kind == .running { cur!.running += dur }
            cur!.lastEnd = end
        }

        var openStart: Date?
        if let c = cur {
            if now.timeIntervalSince(c.lastEnd) < openWithin { openStart = c.start } else { close() }
        }
        return Result(bouts: out, openStart: openStart)
    }

    private static func bout(_ c: Open) -> Bout? {
        let kind: ActivityKind
        switch c.family {
        case .cycle: kind = .ride
        case .foot: kind = (c.running >= runAtLeast && c.running >= runShare * c.moving) ? .run : .walk
        }
        let minimum = kind == .run ? minRun : kind == .walk ? minWalk : minRide
        guard c.moving >= minimum else { return nil }
        return Bout(kind: kind, start: c.start, end: c.lastEnd, movingSeconds: c.moving, runningSeconds: c.running)
    }
}
