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
    /// For saves that happen without a view (auto stop). Set at launch.
    @ObservationIgnored var context: ModelContext?

    /// A recording Loop noticed by itself. Opening the app shows it live.
    func beginAuto(kind: ActivityKind, from: Date, preroll: [PedometerSample]) {
        guard recorder == nil else { return }
        let r = LaunchOptions.makeRecorder(always: true)
        r.history = AutoStart.shared.history
        #if DEBUG
        // UI tests fake stillness by cutting the feeds; the fake motion record would say he kept walking.
        if LaunchOptions.args.contains("-LoopFakeStillAfter") { r.history = nil }
        #endif
        r.startAuto(kind: kind, from: from, preroll: preroll)
        attachAutoStop(r)
        saved = nil
        recorder = r
        showingCover = true
        #if DEBUG
        if let i = LaunchOptions.args.firstIndex(of: "-LoopFakeStillAfter"), i + 1 < LaunchOptions.args.count,
           let secs = Double(LaunchOptions.args[i + 1]) {
            Task { [weak r] in
                try? await Task.sleep(for: .seconds(secs))
                r?.debugCutFeeds()
            }
        }
        #endif
    }

    private func attachAutoStop(_ r: WorkoutRecorder) {
        guard r.isAuto else { return }
        r.onAutoStop = { [weak self, weak r] reason in
            guard let self, let r else { return }
            self.autoFinish(r, reason: reason)
        }
    }

    /// Stops and saves an auto recording through the normal save. Too short: dropped quietly.
    func autoFinish(_ r: WorkoutRecorder, reason: AutoStop.Reason) {
        guard recorder === r, r.state == .recording else { return }
        let raw = r.finishAuto(reason)
        let final = AutoStop.final(raw)
        guard let ctx = context, let result = final else {
            r.draftStore?.clear()
            recorder = nil; showingCover = false
            AutoStart.shared.armHere()
            return
        }
        let defaults = UserDefaults.standard
        let usePlaces = defaults.object(forKey: "usePlaces") as? Bool ?? true
        let health = (defaults.object(forKey: "saveToHealth") as? Bool ?? true) && LaunchOptions.healthAllowed
        Task {
            // A GPS-less pick-up stays out of Health, like other motion-record walks.
            _ = await WorkoutStore.save(result, in: ctx, usePlaces: usePlaces, saveToHealth: health && result.source != "motion")
            r.draftStore?.clear()
            if recorder === r { recorder = nil; showingCover = false }
            toast = "Saved your \(result.kind.noun)"
            AutoStart.shared.armHere()
        }
    }

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
            let (loc, mot, clock) = LaunchOptions.makeSources(origin: origin, always: d.auto ?? false)
            recorder = WorkoutRecorder.restore(d, location: loc, motion: mot, clock: clock,
                                               paused: paused, gap: max(0, clock.now().timeIntervalSince(d.savedAt)),
                                               draftStore: store, powerLog: PowerLog.shared)
            if let r = recorder, r.isAuto { r.history = AutoStart.shared.history; attachAutoStop(r) }
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
            #if DEBUG
            // The fake motion record is relative to each window's end, so a repair would add fake walks.
            if LaunchOptions.args.contains("-LoopFakeMotionHistory") { Repairs.repairsAttempted = true }
            else { await Repairs.runAll(ctx, history: MotionHistory.shared) }
            #else
            await Repairs.runAll(ctx, history: MotionHistory.shared)
            #endif
            // The retry on becoming active waits for the repair; run it now that the repair is done.
            await Repairs.retryHealth(ctx)
            await MotionHistory.shared.scanIfDue(ctx)
            await NudgeScheduler.shared.replan(ctx)
            #if DEBUG
            if LaunchOptions.args.contains("-LoopTestNudge") { await NudgeScheduler.scheduleTestNudge(ctx) }
            #endif
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                env.refresh()
                PowerLog.shared?.log(.foreground)
                Task {
                    await MotionHistory.shared.scanIfDue(ctx)
                    await Repairs.retryHealth(ctx)
                    await NudgeScheduler.shared.replan(ctx)
                }
            }
            if p == .background {
                session.recorder?.persistDraft()
                PowerLog.shared?.log(.background)
                NudgeScheduler.shared.submitRefresh()
            }
        }
    }
}
