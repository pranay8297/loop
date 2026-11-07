import SwiftUI
import SwiftData

@main
struct LoopApp: App {
    let container: ModelContainer
    @State private var session: Session

    init() {
        let args = ProcessInfo.processInfo.arguments
        let inMemory = args.contains("-LoopFreshStore")
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try! ModelContainer(for: Workout.self, configurations: config)
        if args.contains("-LoopResetNudgeAsk") {
            for k in [NudgeScheduler.askDoneKey, NudgeScheduler.nudgesKey, NudgeScheduler.recapKey] {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
        if args.contains("-LoopDraftTest") && args.contains("-LoopClearDraft") { RecordingDraftStore.shared?.clear() }
        PowerLog.shared?.prune()
        #if DEBUG
        if inMemory, let i = args.firstIndex(of: "-LoopFakeRoutes") {
            let n = i + 1 < args.count ? Int(args[i + 1]) ?? 6 : 6
            FakeRoutes.insert(n, into: container.mainContext)
        }
        #endif
        DispatchQueue.main.async {
            // By now UIApplication knows whether Core Location woke the app in the background.
            let bg = UIApplication.shared.applicationState == .background
            PowerLog.shared?.log(.launch, reason: bg ? "background launch" : "launch")
        }
        MetricsStore.shared.start()
        // Restore at launch, not when a view appears: after a background relaunch by Core Location
        // the location session must be recreated immediately.
        let s = Session()
        s.context = container.mainContext
        s.restoreDraft(context: container.mainContext)
        // Re-create the geofence monitor at once: a background launch may be its exit event.
        #if DEBUG
        if let i = args.firstIndex(of: "-LoopFakeWake") {
            let raw = i + 1 < args.count ? args[i + 1] : "walk"
            let kind: ActivityHistorySample.Kind = raw == "ride" ? .cycling : raw == "run" ? .running : .walking
            AutoStart.shared.history = FakeWakeHistory(kind: kind, minutes: 8)
        }
        if args.contains("-LoopAutoStartOn") { UserDefaults.standard.set(true, forKey: AutoStart.enabledKey) }
        if args.contains("-LoopResetAutoAsk") {
            UserDefaults.standard.removeObject(forKey: AutoStart.askDoneKey)
            UserDefaults.standard.removeObject(forKey: AutoStart.enabledKey)
        }
        #endif
        AutoStart.shared.boot(session: s)
        #if DEBUG
        if args.contains("-LoopFakeWake") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await AutoStart.shared.wake(reason: "fake wake", at: nil)
            }
        }
        #endif
        _session = State(initialValue: s)
    }

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
                .tint(Theme.paper)
        }
        .modelContainer(container)
        .backgroundTask(.appRefresh(NudgeScheduler.refreshID)) { [container] in
            await NudgeScheduler.runRefresh(container: container)
        }
    }
}

/// Launch options, with DEBUG-only replay.
enum LaunchOptions {
    static var args: [String] { ProcessInfo.processInfo.arguments }
    static var isReplay: Bool {
        #if DEBUG
        return args.contains("-LoopReplayRoute")
        #else
        return false
        #endif
    }
    static var replaySpeed: Double {
        if let i = args.firstIndex(of: "-LoopReplaySpeed"), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
        return 20
    }
    /// Health writes are skipped in replay unless asked for, so the Health sheet does not block tests.
    static var healthAllowed: Bool { !isReplay || args.contains("-LoopReplayHealth") }

    @MainActor
    static func makeRecorder(always: Bool = false) -> WorkoutRecorder {
        let (loc, mot, clock) = makeSources(origin: Date(), always: always)
        let r = WorkoutRecorder(location: loc, motion: mot, clock: clock)
        r.draftStore = RecordingDraftStore.shared
        r.powerLog = PowerLog.shared
        return r
    }

    /// Sources and clock for a recorder. `origin` is where the clock starts (a restored replay
    /// continues from its saved time).
    static func makeSources(origin: Date, always: Bool = false) -> (LocationSource, MotionSource, RecordingClock) {
        #if DEBUG
        if isReplay {
            let clock = RecordingClock(scale: replaySpeed, origin: origin)
            // Separate feeds so turning GPS off during a pause leaves the pedometer running.
            return (ReplayFeed(clock: clock), ReplayFeed(clock: clock), clock)
        }
        #endif
        return (LiveLocationSource(always: always), LiveMotionSource(), RecordingClock())
    }
}

#if DEBUG
/// Synthetic recorded routes for screenshots and UI tests (in-memory store only).
enum FakeRoutes {
    static let origin = (lat: 25.1575, lon: 55.2000)

    /// Waypoints in metres east/north of the origin. They share a spine, then branch.
    static let shapes: [[(Double, Double)]] = [
        [(0, 0), (400, 300), (900, 650), (1300, 900), (1500, 600), (1100, 250), (600, -100), (0, 0)],
        [(0, 0), (400, 300), (900, 650), (700, 1100), (200, 900), (0, 0)],
        [(0, 0), (400, 300), (900, 650), (1300, 900), (1700, 1250), (1300, 900), (900, 650), (400, 300), (0, 0)],
        [(0, 0), (-300, -400), (100, -800), (600, -100), (0, 0)],
        [(0, 0), (400, 300), (900, 650), (1300, 900), (1500, 600), (1100, 250), (600, -100), (0, 0)],
        [(0, 0), (400, 300), (900, 650), (700, 1100), (200, 900), (0, 0)],
    ]

    static func route(_ shape: [(Double, Double)], start: Date) -> [RoutePoint] {
        let mLat = 111_195.0, mLon = 111_195.0 * cos(origin.lat * .pi / 180)
        var out: [RoutePoint] = []
        var cum = 0.0
        for (a, b) in zip(shape, shape.dropFirst()) {
            let d = hypot(b.0 - a.0, b.1 - a.1)
            let steps = max(1, Int(d / 10))
            for s in 0..<steps {
                let f = Double(s) / Double(steps)
                let x = a.0 + (b.0 - a.0) * f, y = a.1 + (b.1 - a.1) * f
                out.append(RoutePoint(lat: origin.lat + y / mLat, lon: origin.lon + x / mLon, alt: 0,
                                      t: start.addingTimeInterval(cum / 3), speed: 3, hAcc: 5, cumMeters: cum, paused: nil))
                cum += d / Double(steps)
            }
        }
        return out
    }

    @MainActor
    static func insert(_ n: Int, into ctx: ModelContext) {
        for k in 0..<n {
            let start = Date().addingTimeInterval(-Double(k + 1) * 86_400)
            let r = route(shapes[k % shapes.count], start: start)
            let end = r.last?.t ?? start
            let w = Workout(kind: k % 2 == 0 ? .run : .walk, startDate: start, endDate: end,
                            movingSeconds: end.timeIntervalSince(start), distanceMeters: r.last?.cumMeters ?? 0,
                            name: "Sample", route: r)
            ctx.insert(w)
        }
        try? ctx.save()
    }
}
#endif
