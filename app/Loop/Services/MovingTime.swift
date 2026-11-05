import Foundation

/// Moving time from "movement evidence": each gap between consecutive evidence counts up to `grace`,
/// so a long stop adds at most `grace` seconds while normal movement (evidence every 1 to 4 s) counts fully.
/// Gaps that cross a manual pause count only up to the pause; paused time never counts.
struct MovingTime: Equatable {
    static let grace: TimeInterval = 12
    /// Doppler speed that counts as moving on its own (with a good fix).
    static let dopplerMoving = 1.0
    static let dopplerMaxHAcc = 10.0

    /// Seconds counted up to `anchor`.
    private(set) var total: Double = 0
    /// Last evidence (or segment start). Nil while manually paused or before the start.
    private(set) var anchor: Date?

    init() {}

    /// Starts a moving segment (recording start, resume, restore). Nothing before `t` is added.
    mutating func begin(_ t: Date) { anchor = t }

    /// Movement seen at `t`. Out-of-order or paused evidence is ignored.
    mutating func evidence(_ t: Date) {
        guard let a = anchor, t >= a else { return }
        total += min(t.timeIntervalSince(a), Self.grace)
        anchor = t
    }

    /// Ends the segment at `t` (manual pause, finish). The tail counts up to `grace`.
    mutating func pause(_ t: Date) {
        guard let a = anchor else { return }
        total += min(max(0, t.timeIntervalSince(a)), Self.grace)
        anchor = nil
    }

    /// Moving time at `now`: never decreases as `now` advances or evidence arrives.
    func value(at now: Date) -> Double {
        guard let a = anchor else { return total }
        return total + min(max(0, now.timeIntervalSince(a)), Self.grace)
    }

    /// True when a segment is open and nothing has moved for longer than `grace`.
    func isStill(at now: Date) -> Bool {
        guard let a = anchor else { return false }
        return now.timeIntervalSince(a) > Self.grace
    }

    // MARK: evidence rules

    static func isDopplerMoving(speed: Double, hAcc: Double) -> Bool {
        speed >= dopplerMoving && hAcc >= 0 && hAcc <= dopplerMaxHAcc
    }

    // MARK: offline

    private enum Event { case pause, resume, evidence }

    /// Replays a recording: route points (paused flags mark manual pauses), pedometer samples (`usesSteps`),
    /// from `start`; ends at `end` (closed as a finish) unless `end` is nil.
    static func replay(start: Date, end: Date?, points: [RoutePoint], pedo: [PedometerSample],
                       usesSteps: Bool, pauseStarted: Date? = nil) -> MovingTime {
        var events: [(t: Date, e: Event)] = []
        var prev: RoutePoint?
        for p in points {
            if p.isPaused {
                // The interval leading to this point is not moving time. A run of paused points is one pause,
                // from the point before the run to the last paused point.
                if !(prev?.isPaused ?? false) { events.append((prev?.t ?? p.t, .pause)) }
            } else {
                if let q = prev, q.isPaused { events.append((q.t, .resume)) }
                if (prev.map { p.cumMeters > $0.cumMeters } ?? false) || isDopplerMoving(speed: p.speed, hAcc: p.hAcc) {
                    events.append((p.t, .evidence))
                }
            }
            prev = p
        }
        if let last = points.last, last.isPaused { events.append((last.t, .resume)) }
        if usesSteps {
            var last: Int?
            for s in pedo {
                if let l = last, s.steps > l { events.append((s.time, .evidence)) }
                last = s.steps
            }
        }
        if let ps = pauseStarted { events.append((ps, .pause)) }
        // Stable: evidence before pauses before resumes at the same time.
        let rank: (Event) -> Int = { $0 == .evidence ? 0 : $0 == .pause ? 1 : 2 }
        let sorted = events.enumerated().sorted {
            $0.element.t != $1.element.t ? $0.element.t < $1.element.t
                : rank($0.element.e) != rank($1.element.e) ? rank($0.element.e) < rank($1.element.e) : $0.offset < $1.offset
        }.map(\.element)
        var m = MovingTime()
        m.begin(start)
        var pausedOpen = false
        for (t, e) in sorted {
            switch e {
            case .pause: m.pause(t); pausedOpen = true
            case .resume:
                if let ps = pauseStarted, t >= ps { continue }
                m.begin(t); pausedOpen = false
            case .evidence: if !pausedOpen { m.evidence(t) }
            }
        }
        if let end { m.pause(end) }
        return m
    }

    /// Moving seconds of a stored route (no pedometer), for correcting old workouts.
    static func seconds(start: Date, end: Date, route: [RoutePoint]) -> Double {
        replay(start: start, end: end, points: route, pedo: [], usesSteps: false).total
    }
}
