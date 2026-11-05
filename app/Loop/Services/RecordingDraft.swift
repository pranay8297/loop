import Foundation

/// Everything needed to rebuild an in-progress recording after the app was closed.
struct RecordingDraft: Codable, Sendable, Equatable {
    var kind: ActivityKind
    var startDate: Date
    var pausedTotal: Double
    var pauseStarted: Date?
    var wasPaused: Bool
    /// Recorder clock time when this draft was written.
    var savedAt: Date
    var points: [RoutePoint]
    var modes: [MoveKind]
    var motionSamples: [MotionSample]
    var pedo: [PedometerSample]
    var cum: Double
}

/// Stores one draft as JSON in Application Support. Writes are atomic and serialised.
final class RecordingDraftStore: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "loop.recording-draft")

    init(url: URL) { self.url = url }

    static let defaultURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("recording-draft.json")
    }()

    /// Drafts are off for UI tests with a fresh store, unless `-LoopDraftTest` asks for them.
    static var isEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        return !args.contains("-LoopFreshStore") || args.contains("-LoopDraftTest")
    }

    /// The app's store, or nil when drafts are disabled.
    static let shared: RecordingDraftStore? = isEnabled ? RecordingDraftStore(url: defaultURL) : nil

    /// Encodes and writes off the caller's thread. Writes keep their order.
    func save(_ draft: RecordingDraft) {
        queue.async { [url] in
            try? Self.write(draft, to: url)
        }
    }

    /// Encodes and writes now. Used by tests and timing.
    func saveNow(_ draft: RecordingDraft) throws {
        try queue.sync { try Self.write(draft, to: url) }
    }

    /// Returns the draft, or nil. A file that cannot be decoded is removed.
    func load() -> RecordingDraft? {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let d = try? JSONDecoder().decode(RecordingDraft.self, from: data) { return d }
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func clear() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    private static func write(_ draft: RecordingDraft, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(draft)
        try data.write(to: url, options: .atomic)
    }
}

/// What to do with a draft found at launch.
enum RestorePolicy {
    enum Decision: Equatable { case resume, restorePaused, autoSave }

    static let resumeWindow: TimeInterval = 120
    static let autoSaveAfter: TimeInterval = 12 * 3600

    static func decide(age rawAge: TimeInterval, wasPaused: Bool) -> Decision {
        let age = max(0, rawAge)
        if age > autoSaveAfter { return .autoSave }
        if !wasPaused && age <= resumeWindow { return .resume }
        return .restorePaused
    }
}
