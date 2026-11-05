import Foundation
import CoreLocation
import Observation

enum RecorderState: Equatable { case idle, recording, paused, finished }

struct RecordingResult {
    var kind: ActivityKind
    var start: Date
    var end: Date
    var movingSeconds: Double
    var distanceMeters: Double
    var steps: Int?
    var route: [RoutePoint]
    var segments: [MoveSegment]
}

/// Records one workout from a location and a motion source.
@MainActor
@Observable
final class WorkoutRecorder {
    static let maxAccuracy: Double = 25
    static let maxSpeed: Double = 12

    private(set) var state: RecorderState = .idle
    private(set) var kind: ActivityKind = .run
    // Live stats, published at most once a second.
    private(set) var movingSeconds: Double = 0
    private(set) var distanceMeters: Double = 0
    private(set) var paceNow: Double?
    private(set) var cadence: Double?
    private(set) var mode: MoveKind = .run
    private(set) var liveRoute: [RoutePoint] = []
    private(set) var liveModes: [MoveKind] = []

    @ObservationIgnored let clock: RecordingClock
    @ObservationIgnored private let location: LocationSource
    @ObservationIgnored private let motion: MotionSource
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var points: [RoutePoint] = []
    @ObservationIgnored private var modes: [MoveKind] = []
    @ObservationIgnored private var motionSamples: [MotionSample] = []
    @ObservationIgnored private var pedo: [PedometerSample] = []
    @ObservationIgnored private var cum: Double = 0
    @ObservationIgnored private var lastAccepted: RoutePoint?
    @ObservationIgnored private var resumePending = false
    @ObservationIgnored private var startDate: Date = .distantPast
    @ObservationIgnored private var pausedTotal: Double = 0
    @ObservationIgnored private var pauseStarted: Date?

    init(location: LocationSource, motion: MotionSource, clock: RecordingClock = RecordingClock()) {
        self.location = location
        self.motion = motion
        self.clock = clock
    }

    func start(kind: ActivityKind) {
        guard state == .idle else { return }
        self.kind = kind
        startDate = clock.now()
        state = .recording
        let loc = location.fixes()
        tasks.append(Task { [weak self] in
            for await fix in loc { self?.ingest(fix) }
        })
        let acts = motion.activities()
        tasks.append(Task { [weak self] in
            for await a in acts { self?.motionSamples.append(a) }
        })
        let steps = motion.pedometer(from: startDate)
        tasks.append(Task { [weak self] in
            for await p in steps { self?.pedo.append(p) }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                try? await Task.sleep(for: .seconds(1))
            }
        })
    }

    func pause() {
        guard state == .recording else { return }
        state = .paused
        pauseStarted = clock.now()
        publish()
    }

    func resume() {
        guard state == .paused else { return }
        if let p = pauseStarted { pausedTotal += clock.now().timeIntervalSince(p) }
        pauseStarted = nil
        resumePending = true
        state = .recording
        publish()
    }

    func finish() -> RecordingResult {
        if state == .paused { resume() }
        let end = clock.now()
        state = .finished
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        location.stop(); motion.stop()
        publish()
        let samples = segmenterSamples()
        let segs: [MoveSegment]
        switch kind {
        case .run: segs = MotionSegmenter.segments(samples)
        case .walk:
            if let f = points.first, let l = points.last, l.cumMeters > 0 {
                segs = [MoveSegment(kind: .walk, startMeters: 0, endMeters: l.cumMeters, startTime: f.t, endTime: l.t)]
            } else { segs = [] }
        default: segs = []
        }
        return RecordingResult(kind: kind, start: startDate, end: end, movingSeconds: movingTime(at: end),
                               distanceMeters: cum, steps: pedo.last?.steps, route: points, segments: segs)
    }

    // MARK: internals

    private func movingTime(at now: Date) -> Double {
        var paused = pausedTotal
        if let p = pauseStarted { paused += now.timeIntervalSince(p) }
        return max(0, now.timeIntervalSince(startDate) - paused)
    }

    func ingest(_ fix: LocationFix) {
        guard state == .recording || state == .paused else { return }
        guard fix.hAcc >= 0, fix.hAcc <= Self.maxAccuracy else { return }
        var p = RoutePoint(lat: fix.lat, lon: fix.lon, alt: fix.altitude, t: fix.timestamp,
                           speed: fix.speed >= 0 ? fix.speed : -1, hAcc: fix.hAcc, cumMeters: cum, paused: nil)
        if state == .paused {
            p.paused = true
            points.append(p); modes.append(mode)
            lastAccepted = p
            resumePending = true
            return
        }
        if let last = lastAccepted, !resumePending {
            let d = RouteGeometry.distance(last, p)
            let dt = p.t.timeIntervalSince(last.t)
            if dt <= 0 { return }
            if d / dt > Self.maxSpeed { return }
            cum += d
            p.cumMeters = cum
        } else if resumePending {
            p.paused = true
            resumePending = false
        }
        lastAccepted = p
        points.append(p)
        mode = currentMode(at: p)
        modes.append(mode)
    }

    private func currentMode(at p: RoutePoint) -> MoveKind {
        guard kind == .run else { return kind == .walk ? .walk : .run }
        let s = SegmenterSample(time: p.t, cumMeters: p.cumMeters, speed: p.speed,
                                activity: motionSamples.last?.activity, confidence: motionSamples.last?.confidence,
                                cadence: pedo.last?.cadence)
        return MotionSegmenter.vote(s, previous: mode) ?? mode
    }

    private func segmenterSamples() -> [SegmenterSample] {
        var mi = 0, pi = 0
        var out: [SegmenterSample] = []
        for p in points where !p.isPaused {
            while mi + 1 < motionSamples.count, motionSamples[mi + 1].time <= p.t { mi += 1 }
            while pi + 1 < pedo.count, pedo[pi + 1].time <= p.t { pi += 1 }
            let m = motionSamples.indices.contains(mi) && motionSamples[mi].time <= p.t ? motionSamples[mi] : nil
            let c = pedo.indices.contains(pi) && pedo[pi].time <= p.t ? pedo[pi].cadence : nil
            out.append(SegmenterSample(time: p.t, cumMeters: p.cumMeters, speed: p.speed,
                                       activity: m?.activity, confidence: m?.confidence, cadence: c))
        }
        return out
    }

    private func publish() {
        let now = clock.now()
        movingSeconds = movingTime(at: now)
        distanceMeters = cum
        cadence = state == .recording ? pedo.last?.cadence : nil
        // pace over the last ~30 s of moving points
        let recent = points.filter { !$0.isPaused && now.timeIntervalSince($0.t) <= 30 }
        if state == .recording, let a = recent.first, let b = recent.last, b.cumMeters - a.cumMeters > 10 {
            paceNow = b.t.timeIntervalSince(a.t) / ((b.cumMeters - a.cumMeters) / 1000)
        } else { paceNow = nil }
        if liveRoute.count != points.count {
            liveRoute = points
            liveModes = modes
        }
    }
}
