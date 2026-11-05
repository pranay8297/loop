import Foundation
import CoreLocation

/// Decides how much distance each GPS fix adds to a workout.
///
/// Pure and deterministic: no managers, no clocks. All times come from the inputs.
/// It keeps GPS wobble (standing, indoors, stairs) and stale cached fixes from
/// inflating distance, while real outdoor movement measures as before.
struct DistanceFilter {
    enum Decision: Equatable {
        /// Drop the fix entirely (bad accuracy, stale, out of order or implausible jump).
        case reject
        /// Keep the fix; add `increment` meters to the running distance.
        case accept(increment: Double)
    }

    // Tunables.
    static let maxAccuracy: Double = 25
    /// A fix at or below this accuracy is "good" and its position is trusted for distance.
    static let goodAccuracy: Double = 12
    /// A fix up to this accuracy is also trusted when it carries a valid Doppler speed, which only
    /// comes with a satellite lock. City streets often report ~14 m with a solid lock; indoor
    /// Wi-Fi and cell fixes carry no Doppler speed, so they stay "poor".
    static let dopplerGoodAccuracy: Double = 20
    /// Minimum move from the anchor before a good fix counts.
    static let goodMinStep: Double = 4
    /// Minimum move from the anchor before a poor fix counts (no pedometer distance).
    static let poorMinStep: Double = 8
    static let poorAccuracyFactor: Double = 1.5
    /// No step increase for this long means the walker/runner is standing still.
    static let stepIdle: TimeInterval = 6
    /// Doppler speed and accuracy that prove movement even when the pedometer is silent.
    static let dopplerMoving: Double = 1.0
    static let dopplerAccuracy: Double = 10
    /// A valid Doppler speed below this on an accurate fix means we are stopped.
    static let dopplerStopped: Double = 0.3

    static func maxSpeed(_ kind: ActivityKind) -> Double {
        switch kind {
        case .walk: 4
        case .run: 9
        case .ride: 25
        default: 12
        }
    }

    let kind: ActivityKind
    let start: Date

    private var anchor: CLLocation?
    private var lastT: Date?
    private var lastWasGood = false
    private var paused = false
    private var reanchor = false

    // Pedometer
    private var stepsSeen = false
    private var lastSteps = 0
    private var lastStepIncrease: Date?
    private var pedoDistance: Double?
    private var consumed: Double = 0

    init(kind: ActivityKind, start: Date) {
        self.kind = kind
        self.start = start
    }

    private var usesSteps: Bool { kind == .walk || kind == .run }

    mutating func pedometer(_ s: PedometerSample) {
        if s.steps > 0 { stepsSeen = true }
        if s.steps > lastSteps {
            lastSteps = s.steps
            if lastStepIncrease.map({ s.time > $0 }) ?? true { lastStepIncrease = s.time }
        }
        if let d = s.distance { pedoDistance = max(pedoDistance ?? 0, d) }
    }

    mutating func pause() { paused = true }

    /// The next fix re-anchors and skips pedometer distance accrued while paused.
    /// Best effort: the pedometer lags about 2 s, so a little paused distance may still arrive later.
    mutating func resume() {
        paused = false
        reanchor = true
    }

    mutating func fix(_ f: LocationFix) -> Decision {
        // a. accuracy
        guard f.hAcc >= 0, f.hAcc <= Self.maxAccuracy else { return .reject }
        // b. freshness
        guard f.timestamp >= start.addingTimeInterval(-1) else { return .reject }
        if let t = lastT, f.timestamp <= t { return .reject }

        let loc = stamped(CLLocation(latitude: f.lat, longitude: f.lon), f.timestamp)
        let good = f.hAcc <= Self.goodAccuracy || (f.hAcc <= Self.dopplerGoodAccuracy && f.speed >= 0)
        let stepMode = !good && usesSteps && pedoDistance != nil

        if paused || reanchor || anchor == nil {
            lastT = f.timestamp
            anchor = loc
            lastWasGood = good
            consumed = pedoDistance ?? 0
            if !paused { reanchor = false }
            return .accept(increment: 0)
        }

        // c. per-kind max speed from the anchor
        let a = anchor!
        let d = loc.distance(from: a)
        let dt = f.timestamp.timeIntervalSince(a.timestamp)
        if dt > 0, d / dt > Self.maxSpeed(kind) { return .reject }
        lastT = f.timestamp

        let wasGood = lastWasGood
        lastWasGood = good

        if stepMode {
            let latest = pedoDistance ?? consumed
            let inc = max(0, latest - consumed)
            consumed = max(consumed, latest)
            anchor = loc
            return .accept(increment: inc)
        }

        if good {
            // Pedometer distance covered by GPS is never counted again later.
            if let p = pedoDistance { consumed = max(consumed, p) }
            if !wasGood {
                anchor = loc
                return .accept(increment: 0)
            }
        }

        if f.isStationary == true || dopplerStopped(f) || stepGateClosed(f) { return .accept(increment: 0) }

        let threshold = good ? max(Self.goodMinStep, f.hAcc)
                             : max(Self.poorMinStep, Self.poorAccuracyFactor * f.hAcc)
        guard d >= threshold else { return .accept(increment: 0) }
        anchor = loc
        return .accept(increment: d)
    }

    private func dopplerStopped(_ f: LocationFix) -> Bool {
        f.speed >= 0 && f.speed < Self.dopplerStopped && f.hAcc <= Self.dopplerAccuracy
    }

    private func stepGateClosed(_ f: LocationFix) -> Bool {
        guard usesSteps, stepsSeen, let last = lastStepIncrease else { return false }
        guard f.timestamp.timeIntervalSince(last) > Self.stepIdle else { return false }
        let dopplerMoving = f.speed >= Self.dopplerMoving && f.hAcc <= Self.dopplerAccuracy
        return !dopplerMoving
    }

    private func stamped(_ l: CLLocation, _ t: Date) -> CLLocation {
        CLLocation(coordinate: l.coordinate, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: -1, timestamp: t)
    }
}
