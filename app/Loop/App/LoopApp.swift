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
        if args.contains("-LoopDraftTest") && args.contains("-LoopClearDraft") { RecordingDraftStore.shared?.clear() }
        PowerLog.shared?.prune()
        DispatchQueue.main.async {
            // By now UIApplication knows whether Core Location woke the app in the background.
            let bg = UIApplication.shared.applicationState == .background
            PowerLog.shared?.log(.launch, reason: bg ? "background launch" : "launch")
        }
        MetricsStore.shared.start()
        // Restore at launch, not when a view appears: after a background relaunch by Core Location
        // the location session must be recreated immediately.
        let s = Session()
        s.restoreDraft(context: container.mainContext)
        _session = State(initialValue: s)
    }

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .preferredColorScheme(.dark)
                .tint(Theme.paper)
        }
        .modelContainer(container)
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
    static func makeRecorder() -> WorkoutRecorder {
        let (loc, mot, clock) = makeSources(origin: Date())
        let r = WorkoutRecorder(location: loc, motion: mot, clock: clock)
        r.draftStore = RecordingDraftStore.shared
        r.powerLog = PowerLog.shared
        return r
    }

    /// Sources and clock for a recorder. `origin` is where the clock starts (a restored replay
    /// continues from its saved time).
    static func makeSources(origin: Date) -> (LocationSource, MotionSource, RecordingClock) {
        #if DEBUG
        if isReplay {
            let clock = RecordingClock(scale: replaySpeed, origin: origin)
            // Separate feeds so turning GPS off during a pause leaves the pedometer running.
            return (ReplayFeed(clock: clock), ReplayFeed(clock: clock), clock)
        }
        #endif
        return (LiveLocationSource(), LiveMotionSource(), RecordingClock())
    }
}
