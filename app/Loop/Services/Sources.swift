import Foundation
import CoreLocation
import CoreMotion

struct LocationFix: Sendable {
    var lat: Double
    var lon: Double
    var altitude: Double
    var speed: Double
    var hAcc: Double
    var timestamp: Date
    var isStationary: Bool?
}

enum MotionActivity: String, Sendable { case running, walking, stationary, other }
enum MotionConfidence: Int, Sendable, Comparable {
    case low = 0, medium = 1, high = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct MotionSample: Sendable {
    var time: Date
    var activity: MotionActivity
    var confidence: MotionConfidence
}

struct PedometerSample: Sendable {
    var time: Date
    var steps: Int
    /// steps per minute
    var cadence: Double?
    /// cumulative meters since start, from the pedometer (nil when unavailable)
    var distance: Double? = nil
}

protocol LocationSource: AnyObject {
    func fixes() -> AsyncStream<LocationFix>
    func stop()
}

protocol MotionSource: AnyObject {
    func activities() -> AsyncStream<MotionSample>
    func pedometer(from start: Date) -> AsyncStream<PedometerSample>
    func stop()
}

/// Virtual clock so replays at N times speed still produce real-looking times.
final class RecordingClock: @unchecked Sendable {
    let origin = Date()
    let scale: Double
    init(scale: Double = 1) { self.scale = scale }
    func now() -> Date { origin.addingTimeInterval(Date().timeIntervalSince(origin) * scale) }
}

// MARK: Live

final class LiveLocationSource: LocationSource {
    private var task: Task<Void, Never>?
    private var background: CLBackgroundActivitySession?
    private var service: CLServiceSession?

    func fixes() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            // Keeps updates flowing with the screen locked (blue indicator).
            background = CLBackgroundActivitySession()
            service = CLServiceSession(authorization: .whenInUse)
            task = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                        if Task.isCancelled { break }
                        guard let l = update.location else { continue }
                        continuation.yield(LocationFix(
                            lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                            altitude: l.altitude, speed: l.speed, hAcc: l.horizontalAccuracy,
                            timestamp: l.timestamp, isStationary: update.stationary))
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in self?.task?.cancel() }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        background?.invalidate(); background = nil
        service?.invalidate(); service = nil
    }
}

final class LiveMotionSource: MotionSource {
    private let activityManager = CMMotionActivityManager()
    private let pedometerManager = CMPedometer()

    func activities() -> AsyncStream<MotionSample> {
        AsyncStream { continuation in
            guard CMMotionActivityManager.isActivityAvailable() else { continuation.finish(); return }
            activityManager.startActivityUpdates(to: .main) { a in
                guard let a else { return }
                let kind: MotionActivity = a.running ? .running : a.walking ? .walking : a.stationary ? .stationary : .other
                let conf: MotionConfidence = switch a.confidence {
                case .high: .high
                case .medium: .medium
                default: .low
                }
                continuation.yield(MotionSample(time: a.startDate, activity: kind, confidence: conf))
            }
        }
    }

    func pedometer(from start: Date) -> AsyncStream<PedometerSample> {
        AsyncStream { continuation in
            guard CMPedometer.isStepCountingAvailable() else { continuation.finish(); return }
            pedometerManager.startUpdates(from: start) { data, _ in
                guard let data else { return }
                let cadence = data.currentCadence.map { $0.doubleValue * 60 }
                continuation.yield(PedometerSample(time: data.endDate, steps: data.numberOfSteps.intValue, cadence: cadence,
                                                   distance: data.distance?.doubleValue))
            }
        }
    }

    func stop() {
        activityManager.stopActivityUpdates()
        pedometerManager.stopUpdates()
    }
}

// MARK: Replay (DEBUG only)

#if DEBUG
struct ReplayPoint: Decodable { let lat: Double; let lon: Double; let t: Double; let speed: Double; let alt: Double }

/// Replays a bundled route as both a location and a motion source.
final class ReplayFeed: LocationSource, MotionSource {
    let clock: RecordingClock
    let points: [ReplayPoint]
    private var tasks: [Task<Void, Never>] = []

    init(clock: RecordingClock) {
        self.clock = clock
        if let url = Bundle.main.url(forResource: "ReplayRoute", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let pts = try? JSONDecoder().decode([ReplayPoint].self, from: data) {
            points = pts
        } else {
            points = []
        }
    }

    /// Calls `body` for each point when its virtual time arrives.
    private func play(_ body: @escaping (ReplayPoint, Date) -> Void, finish: @escaping () -> Void) -> Task<Void, Never> {
        let pts = points, clock = clock
        return Task {
            let base = clock.now()
            for p in pts {
                if Task.isCancelled { break }
                let due = base.addingTimeInterval(p.t)
                let wait = due.timeIntervalSince(clock.now()) / clock.scale
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { break }
                body(p, due)
            }
            finish()
        }
    }

    func fixes() -> AsyncStream<LocationFix> {
        AsyncStream { c in
            tasks.append(play({ p, due in
                c.yield(LocationFix(lat: p.lat, lon: p.lon, altitude: p.alt, speed: p.speed, hAcc: 5, timestamp: due, isStationary: false))
            }, finish: { c.finish() }))
        }
    }

    func activities() -> AsyncStream<MotionSample> {
        AsyncStream { c in
            var last: MotionActivity?
            tasks.append(play({ p, due in
                let a: MotionActivity = p.speed >= 2.2 ? .running : .walking
                if a != last { last = a; c.yield(MotionSample(time: due, activity: a, confidence: .high)) }
            }, finish: { c.finish() }))
        }
    }

    func pedometer(from start: Date) -> AsyncStream<PedometerSample> {
        AsyncStream { c in
            var steps = 0.0
            var lastT = 0.0
            tasks.append(play({ p, due in
                let cadence = p.speed >= 2.2 ? 166.0 : 112.0
                steps += cadence / 60 * (p.t - lastT); lastT = p.t
                if Int(p.t) % 3 == 0 { c.yield(PedometerSample(time: due, steps: Int(steps), cadence: cadence, distance: nil)) }
            }, finish: { c.finish() }))
        }
    }

    func stop() { tasks.forEach { $0.cancel() }; tasks.removeAll() }
}
#endif
