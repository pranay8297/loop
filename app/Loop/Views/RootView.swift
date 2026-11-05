import SwiftUI
import SwiftData

/// Holds the active recording and the just-saved workout.
@MainActor
@Observable
final class Session {
    var recorder: WorkoutRecorder?
    var saved: Workout?
    var showingCover = false
    var toast: String?

    /// Brings back a recording that was in progress when the app was closed.
    func restoreDraft(context: ModelContext) {
        guard let store = RecordingDraftStore.shared, let d = store.load() else { return }
        // A replay clock runs ahead of real time, so it restarts at the saved time.
        let origin = LaunchOptions.isReplay ? max(Date(), d.savedAt) : Date()
        let age = origin.timeIntervalSince(d.savedAt)
        switch RestorePolicy.decide(age: age, wasPaused: d.wasPaused) {
        case .autoSave:
            let result = WorkoutRecorder.result(from: d)
            let defaults = UserDefaults.standard
            let usePlaces = defaults.object(forKey: "usePlaces") as? Bool ?? true
            let health = (defaults.object(forKey: "saveToHealth") as? Bool ?? true) && LaunchOptions.healthAllowed
            Task {
                _ = await WorkoutStore.save(result, in: context, usePlaces: usePlaces, saveToHealth: health)
                store.clear()
                toast = "Saved your \(d.kind.noun) from earlier"
            }
        case .resume, .restorePaused:
            let paused = RestorePolicy.decide(age: age, wasPaused: d.wasPaused) == .restorePaused
            let (loc, mot, clock) = LaunchOptions.makeSources(origin: origin)
            recorder = WorkoutRecorder.restore(d, location: loc, motion: mot, clock: clock,
                                               paused: paused, gap: max(0, clock.now().timeIntervalSince(d.savedAt)),
                                               draftStore: store, powerLog: PowerLog.shared)
            saved = nil
            showingCover = true
        }
    }
}

struct RootView: View {
    @Bindable var session: Session
    @State private var env = DeviceEnvironmentProvider(forceReady: LaunchOptions.isReplay)
    @State private var tab = 0
    @Environment(\.scenePhase) private var phase
    @Environment(\.modelContext) private var ctx

    var body: some View {
        TabView(selection: $tab) {
            Tab("Start", systemImage: "circle.circle", value: 0) {
                StartView(session: session, env: env)
            }
            Tab("You", systemImage: "person", value: 1) {
                YouView()
            }
        }
        .background(Theme.ink)
        .overlay(alignment: .bottom) {
            if let t = session.toast {
                Toast(text: t).padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { session.toast = nil }
                    }
            }
        }
        .fullScreenCover(isPresented: $session.showingCover) {
            Group {
                if let w = session.saved {
                    NavigationStack {
                        SummaryView(workout: w, justSaved: true) {
                            session.showingCover = false
                            session.saved = nil
                            session.recorder = nil
                        }
                    }
                } else if let r = session.recorder {
                    RecordingView(recorder: r) { saved in session.saved = saved }
                }
            }
            .preferredColorScheme(.dark)
        }
        .task {
            WorkoutStore.correctMovingTimeOnce(ctx)
            await MotionHistory.shared.scanIfDue(ctx)
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                env.refresh()
                PowerLog.shared?.log(.foreground)
                Task { await MotionHistory.shared.scanIfDue(ctx) }
            }
            if p == .background {
                session.recorder?.persistDraft()
                PowerLog.shared?.log(.background)
            }
        }
    }
}
