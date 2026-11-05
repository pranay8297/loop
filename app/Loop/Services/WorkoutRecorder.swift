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
    /// When the app was closed, for a recording restored in the paused state. Cleared on resume.
    private(set) var closedAt: Date?
    /// Recording, not paused, and nothing has moved for longer than `MovingTime.grace`: the clock is frozen.
    private(set) var isStill = false

    /// Where drafts go. Nil disables drafts (tests, fresh-store UI tests).
    @ObservationIgnored var draftStore: RecordingDraftStore?
    @ObservationIgnored private var lastDraftWrite: Date = .distantPast

    @ObservationIgnored let clock: RecordingClock
    @ObservationIgnored private let location: LocationSource
    @ObservationIgnored private let motion: MotionSource
    @ObservationIgnored private var points: [RoutePoint] = []
    @ObservationIgnored private var modes: [MoveKind] = []
    @ObservationIgnored private var motionSamples: [MotionSample] = []
    @ObservationIgnored private var pedo: [PedometerSample] = []
    @ObservationIgnored private var cum: Double = 0
    @ObservationIgnored private var filter = DistanceFilter(kind: .run, start: .distantPast)
    @ObservationIgnored private var lastAccepted: RoutePoint?
    @ObservationIgnored private var resumePending = false
    @ObservationIgnored private var startDate: Date = .distantPast
    @ObservationIgnored private var pausedTotal: Double = 0
    @ObservationIgnored private var pauseStarted: Date?
    @ObservationIgnored private var moving = MovingTime()

    init(location: LocationSource, motion: MotionSource, clock: RecordingClock = RecordingClock()) {
        self.location = location
        self.motion = motion
        self.clock = clock
    }

    func start(kind: ActivityKind) {
        guard state == .idle else { return }
        self.kind = kind
        startDate = clock.now()
        filter = DistanceFilter(kind: kind, start: startDate)
        moving = MovingTime()
        moving.begin(startDate)
        state = .recording
        startSources(reason: "recording start")
        persistDraft()
    }

    /// How long a pause may keep GPS on before Loop turns it off to save battery.
    static let gpsOffAfterPause: TimeInterval = 180

    /// True while the location source is running.
    private(set) var gpsOn = false
    /// Where GPS on/off events go. Nil in tests unless set.
    @ObservationIgnored var powerLog: PowerLog?
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var pedometerTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private func startSources(reason: String) {
        startLocation(reason: reason)
        startPedometer()
        startTick()
    }

    private func startLocation(reason: String) {
        guard !gpsOn else { return }
        gpsOn = true
        powerLog?.log(.gpsOn, reason: reason)
        let loc = location.fixes()
        locationTask = Task { [weak self] in
            for await fix in loc { self?.ingest(fix) }
        }
        let acts = motion.activities()
        activityTask = Task { [weak self] in
            for await a in acts { self?.motionSamples.append(a) }
        }
    }

    /// Turns GPS (and activity updates) off. The background location session ends with it,
    /// so a paused recording no longer keeps the app running.
    private func stopLocation(reason: String) {
        guard gpsOn else { return }
        gpsOn = false
        locationTask?.cancel(); locationTask = nil
        activityTask?.cancel(); activityTask = nil
        location.stop()
        motion.stopActivities()
        powerLog?.log(.gpsOff, reason: reason)
    }

    private func startPedometer() {
        guard pedometerTask == nil else { return }
        let steps = motion.pedometer(from: startDate)
        pedometerTask = Task { [weak self] in
            for await p in steps { self?.ingestPedometer(p) }
        }
    }

    private func startTick() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                self?.checkPauseTimeout()
                self?.persistDraftIfDue()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Turns GPS off once a pause has lasted `gpsOffAfterPause`. Called every second.
    func checkPauseTimeout() {
        guard state == .paused, gpsOn, let p = pauseStarted,
              clock.now().timeIntervalSince(p) >= Self.gpsOffAfterPause else { return }
        stopLocation(reason: "pause timeout")
    }

    func pause() {
        guard state == .recording else { return }
        state = .paused
        pauseStarted = clock.now()
        moving.pause(pauseStarted!)
        filter.pause()
        publish()
        persistDraft()
    }

    func resume() {
        guard state == .paused else { return }
        if let p = pauseStarted { pausedTotal += clock.now().timeIntervalSince(p) }
        pauseStarted = nil
        moving.begin(clock.now())
        resumePending = true
        filter.resume()
        state = .recording
        closedAt = nil
        startLocation(reason: "resume")
        startPedometer()
        startTick()
        publish()
        persistDraft()
    }

    func finish() -> RecordingResult {
        let end = clock.now()
        if state == .paused {
            // Close the pause without turning GPS back on.
            if let p = pauseStarted { pausedTotal += end.timeIntervalSince(p) }
            pauseStarted = nil
            closedAt = nil
        }
        moving.pause(end)
        state = .finished
        for t in [locationTask, activityTask, pedometerTask, tickTask] { t?.cancel() }
        locationTask = nil; activityTask = nil; pedometerTask = nil; tickTask = nil
        if gpsOn { gpsOn = false; powerLog?.log(.gpsOff, reason: "finish") }
        location.stop(); motion.stop()
        publish()
        return Self.buildResult(kind: kind, start: startDate, end: end, movingSeconds: min(moving.total, movingTime(at: end)),
                                cum: cum, points: points, motionSamples: motionSamples, pedo: pedo)
    }

    // MARK: drafts

    /// A snapshot of everything needed to rebuild this recording.
    func draft() -> RecordingDraft {
        RecordingDraft(kind: kind, startDate: startDate, pausedTotal: pausedTotal, pauseStarted: pauseStarted,
                       wasPaused: state == .paused, savedAt: clock.now(), points: points, modes: modes,
                       motionSamples: motionSamples, pedo: pedo, cum: cum)
    }

    /// Writes the draft now (encoded and written off the main thread).
    func persistDraft() {
        guard let store = draftStore, state == .recording || state == .paused else { return }
        lastDraftWrite = Date()
        store.save(draft())
    }

    private func persistDraftIfDue() {
        if Date().timeIntervalSince(lastDraftWrite) >= 10 { persistDraft() }
    }

    /// Rebuilds a recorder from a draft. A recording restored paused keeps GPS off until `resume()`.
    /// `paused`: come back paused, the pause starting when the draft was saved (or its own pause).
    /// Otherwise resume recording, leaving the `gap` since the save out of moving time.
    static func restore(_ d: RecordingDraft, location: LocationSource, motion: MotionSource, clock: RecordingClock,
                        paused: Bool, gap: TimeInterval, draftStore: RecordingDraftStore? = nil,
                        powerLog: PowerLog? = nil) -> WorkoutRecorder {
        let r = WorkoutRecorder(location: location, motion: motion, clock: clock)
        r.draftStore = draftStore
        r.powerLog = powerLog
        r.kind = d.kind
        r.startDate = d.startDate
        r.points = d.points
        r.modes = d.modes
        r.motionSamples = d.motionSamples
        r.pedo = d.pedo
        r.cum = d.cum
        r.pausedTotal = d.pausedTotal
        r.lastAccepted = d.points.last
        if let m = d.modes.last { r.mode = m } else { r.mode = d.kind == .walk ? .walk : .run }
        r.filter = DistanceFilter(kind: d.kind, start: d.startDate)
        for p in d.pedo { r.filter.pedometer(p) }
        // Moving time up to the save; the time the app was closed adds nothing.
        r.moving = MovingTime.replay(start: d.startDate, end: d.savedAt, points: d.points, pedo: d.pedo,
                                     usesSteps: d.kind != .ride, pauseStarted: d.pauseStarted)
        if paused {
            r.state = .paused
            r.pauseStarted = d.pauseStarted ?? d.savedAt
            r.closedAt = d.savedAt
            r.filter.pause()
        } else {
            // Time the app was not running is not moving time.
            if let p = d.pauseStarted { r.pausedTotal += max(0, d.savedAt.timeIntervalSince(p)) }
            r.pausedTotal += max(0, gap)
            r.state = .recording
            r.filter.resume()
            r.moving.begin(clock.now())
            r.resumePending = true
        }
        if paused {
            // GPS and motion stay off until the user resumes.
            r.startTick()
        } else {
            r.startSources(reason: "restore")
        }
        r.publish()
        r.persistDraft()
        return r
    }

    /// The workout a draft describes, ending when it was saved. Used to auto-save old drafts.
    static func result(from d: RecordingDraft) -> RecordingResult {
        var paused = d.pausedTotal
        if let p = d.pauseStarted { paused += max(0, d.savedAt.timeIntervalSince(p)) }
        let wall = max(0, d.savedAt.timeIntervalSince(d.startDate) - paused)
        let moving = min(wall, MovingTime.replay(start: d.startDate, end: d.savedAt, points: d.points, pedo: d.pedo,
                                                 usesSteps: d.kind != .ride, pauseStarted: d.pauseStarted).total)
        return buildResult(kind: d.kind, start: d.startDate, end: d.savedAt, movingSeconds: moving, cum: d.cum,
                           points: d.points, motionSamples: d.motionSamples, pedo: d.pedo)
    }

    private static func buildResult(kind: ActivityKind, start: Date, end: Date, movingSeconds: Double, cum: Double,
                                    points: [RoutePoint], motionSamples: [MotionSample],
                                    pedo: [PedometerSample]) -> RecordingResult {
        let segs: [MoveSegment]
        switch kind {
        case .run: segs = MotionSegmenter.segments(segmenterSamples(points: points, motionSamples: motionSamples, pedo: pedo))
        case .walk:
            if let f = points.first, let l = points.last, l.cumMeters > 0 {
                segs = [MoveSegment(kind: .walk, startMeters: 0, endMeters: l.cumMeters, startTime: f.t, endTime: l.t)]
            } else { segs = [] }
        default: segs = []
        }
        return RecordingResult(kind: kind, start: start, end: end, movingSeconds: movingSeconds,
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
        let decision = filter.fix(fix)
        if state == .recording {
            var moved = MovingTime.isDopplerMoving(speed: fix.speed, hAcc: fix.hAcc)
            if case .accept(let inc) = decision, inc > 0, !resumePending { moved = true }
            if moved { moving.evidence(fix.timestamp) }
        }
        guard case .accept(let increment) = decision else { return }
        var p = RoutePoint(lat: fix.lat, lon: fix.lon, alt: fix.altitude, t: fix.timestamp,
                           speed: fix.speed >= 0 ? fix.speed : -1, hAcc: fix.hAcc, cumMeters: cum, paused: nil)
        if state == .paused {
            p.paused = true
            points.append(p); modes.append(mode)
            lastAccepted = p
            resumePending = true
            return
        }
        if resumePending {
            p.paused = true
            resumePending = false
        } else {
            cum += increment
            p.cumMeters = cum
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

    private static func segmenterSamples(points: [RoutePoint], motionSamples: [MotionSample],
                                         pedo: [PedometerSample]) -> [SegmenterSample] {
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

    func ingestPedometer(_ p: PedometerSample) {
        if state == .recording, kind != .ride, let last = pedo.last, p.steps > last.steps {
            moving.evidence(p.time)
        }
        pedo.append(p)
        filter.pedometer(p)
    }

    /// Publishes now, as the 1 s tick does. For tests with a hand-moved clock.
    func tickForTests() { publish() }

    private func publish() {
        let now = clock.now()
        let m = min(moving.value(at: now), movingTime(at: now))
        // Live time never goes backwards.
        movingSeconds = state == .idle ? m : max(movingSeconds, m)
        let still = state == .recording && moving.isStill(at: now)
        if still != isStill { isStill = still }
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
