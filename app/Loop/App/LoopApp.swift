import SwiftUI
import SwiftData

@main
struct LoopApp: App {
    let container: ModelContainer

    init() {
        let args = ProcessInfo.processInfo.arguments
        let inMemory = args.contains("-LoopFreshStore")
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try! ModelContainer(for: Workout.self, configurations: config)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
        #if DEBUG
        if isReplay {
            let clock = RecordingClock(scale: replaySpeed)
            let feed = ReplayFeed(clock: clock)
            return WorkoutRecorder(location: feed, motion: feed, clock: clock)
        }
        #endif
        return WorkoutRecorder(location: LiveLocationSource(), motion: LiveMotionSource())
    }
}
