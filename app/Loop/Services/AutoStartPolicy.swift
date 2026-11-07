import Foundation

/// Decides, on a low-power wake, whether he has just set off. Pure; all times are absolute Dates.
enum AutoStartPolicy {
    /// How much motion history a wake reads.
    static let window: TimeInterval = 600
    /// Running or cycling this recently starts at once.
    static let quickWindow: TimeInterval = 120
    /// Walking needs `walkNeeded` seconds within the last `walkWindow`.
    static let walkWindow: TimeInterval = 300
    static let walkNeeded: TimeInterval = 180
    /// Any automotive sample this recently means he is in a car.
    static let carWindow: TimeInterval = 120
    /// The start date never goes further back than this.
    static let maxPreroll: TimeInterval = 900

    enum Decision: Equatable {
        case start(kind: ActivityKind, from: Date)
        case ignore(String)
    }

    static func decide(_ raw: [ActivityHistorySample], now: Date, recording: Bool) -> Decision {
        if recording { return .ignore("already recording") }
        let s = raw.sorted { $0.start < $1.start }

        /// Seconds of the given kinds (medium confidence or better, unless `anyConfidence`) inside the last `w`.
        func seconds(_ kinds: Set<ActivityHistorySample.Kind>, within w: TimeInterval, anyConfidence: Bool = false) -> Double {
            let from = now.addingTimeInterval(-w)
            var total = 0.0
            for (i, x) in s.enumerated() where kinds.contains(x.kind) && (anyConfidence || x.confidence >= .medium) {
                let end = i + 1 < s.count ? s[i + 1].start : now
                total += max(0, min(end, now).timeIntervalSince(max(x.start, from)))
            }
            return total
        }

        if seconds([.automotive], within: carWindow, anyConfidence: true) > 0 { return .ignore("in a car") }
        let kind: ActivityKind
        if seconds([.cycling], within: quickWindow) > 0 {
            kind = .ride
        } else if seconds([.running], within: quickWindow) > 0
                    || seconds([.walking, .running], within: walkWindow) >= walkNeeded {
            kind = .run
        } else {
            let walked = Int(seconds([.walking, .running], within: walkWindow) / 60)
            return .ignore(walked > 0 ? "only \(walked) min on foot" : "not moving")
        }
        return .start(kind: kind, from: startOfMovement(s, now: now))
    }

    /// When the current movement began: the open bout's start from the motion record, else the first
    /// confident movement in the window. Never more than `maxPreroll` back.
    static func startOfMovement(_ s: [ActivityHistorySample], now: Date) -> Date {
        let moving: Set<ActivityHistorySample.Kind> = [.walking, .running, .cycling]
        let open = BoutDetector.detect(s, now: now).openStart
        let first = s.first { moving.contains($0.kind) && $0.confidence >= .medium && $0.start >= now.addingTimeInterval(-window) }?.start
        let from = open ?? first ?? now
        return min(now, max(from, now.addingTimeInterval(-maxPreroll)))
    }

    /// Pedometer evidence for the pre-roll: cumulative steps and metres spread evenly every `every`
    /// seconds from `from` to `to`. With no steps (a ride, or no pedometer) the samples carry only time.
    static func preroll(from: Date, to: Date, steps: Int, meters: Double?, every: TimeInterval = 10) -> [PedometerSample] {
        let span = to.timeIntervalSince(from)
        guard span > 0 else { return [] }
        var out: [PedometerSample] = []
        var t = every
        while true {
            let at = min(t, span)
            let f = at / span
            out.append(PedometerSample(time: from.addingTimeInterval(at), steps: Int((Double(steps) * f).rounded()),
                                       cadence: nil, distance: meters.map { $0 * f }))
            if at >= span { break }
            t += every
        }
        return out
    }
}

/// When a recording Loop started by itself should stop. Pure.
enum AutoStop {
    enum Reason: String, Equatable { case still, car, cap }

    static let stillAfter: TimeInterval = 300
    static let carAfter: TimeInterval = 60
    static let cap: TimeInterval = 3 * 3600

    static func check(now: Date, start: Date, lastEvidence: Date, automotiveSince: Date?) -> Reason? {
        if let c = automotiveSince, now.timeIntervalSince(c) > carAfter { return .car }
        if now.timeIntervalSince(lastEvidence) >= stillAfter { return .still }
        if now.timeIntervalSince(start) >= cap { return .cap }
        return nil
    }

    /// The workout an auto recording saves as, or nil to discard it. On foot it is a walk unless running
    /// is at least 10% of the distance; anything under the motion-record minimums is dropped.
    static func final(_ r: RecordingResult) -> RecordingResult? {
        var out = r
        if r.kind == .ride {
            return r.movingSeconds >= BoutDetector.minRide ? r : nil
        }
        let run = r.segments.filter { $0.kind == .run }.reduce(0) { $0 + $1.meters }
        let share = r.distanceMeters > 0 ? run / r.distanceMeters : 0
        out.kind = share >= 0.1 ? .run : .walk
        if out.kind == .walk {
            if let f = r.route.first, let l = r.route.last, l.cumMeters > f.cumMeters {
                out.segments = [MoveSegment(kind: .walk, startMeters: f.cumMeters, endMeters: l.cumMeters,
                                            startTime: f.t, endTime: l.t)]
            } else { out.segments = [] }
        }
        let minimum = out.kind == .run ? BoutDetector.minRun : BoutDetector.minWalk
        return out.movingSeconds >= minimum ? out : nil
    }
}
