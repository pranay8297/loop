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
}

struct RootView: View {
    @State private var session = Session()
    @State private var env = DeviceEnvironmentProvider(forceReady: LaunchOptions.isReplay)
    @State private var tab = 0
    @Environment(\.scenePhase) private var phase

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
        .onChange(of: phase) { _, p in if p == .active { env.refresh() } }
    }
}
