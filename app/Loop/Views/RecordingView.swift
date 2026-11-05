import SwiftUI
import SwiftData
import MapKit

struct RecordingView: View {
    let recorder: WorkoutRecorder
    let onSaved: (Workout) -> Void
    @Environment(\.modelContext) private var ctx
    @AppStorage("usePlaces") private var usePlaces = true
    @AppStorage("saveToHealth") private var saveToHealth = true
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var saving = false

    var body: some View {
        ZStack(alignment: .top) {
            map.ignoresSafeArea()
            HStack(spacing: 6) {
                BlinkingDot()
                Text(modeText).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.paper)
                    .accessibilityIdentifier("liveMode")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Theme.ink.opacity(0.82)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { sheet }
        .background(Theme.ink)
        .onChange(of: recorder.liveRoute.count) { _, _ in follow() }
    }

    private var modeText: String {
        if recorder.state == .paused { return "Paused" }
        if recorder.isStill { return "Standing still" }
        if recorder.kind == .ride { return "Riding" }
        return recorder.mode == .run && recorder.kind == .run ? "Running" : "Walking"
    }

    private var map: some View { LiveMonoMap(recorder: recorder, camera: $camera) }

    private func follow() {
        guard LaunchOptions.isReplay, let last = recorder.liveRoute.last else { return }
        camera = .camera(MapCamera(centerCoordinate: .init(latitude: last.lat, longitude: last.lon), distance: 2200))
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel("Time")
            Text(Format.duration(recorder.movingSeconds))
                .font(Theme.number(76)).foregroundStyle(Theme.paper).padding(.top, 4)
                .accessibilityIdentifier("liveTime")
            if let closed = recorder.closedAt {
                Text("Loop closed at \(closed.formatted(date: .omitted, time: .shortened)). Resume, or hold to stop.")
                    .font(.system(size: 13)).foregroundStyle(Theme.dim).padding(.top, 2)
                    .accessibilityIdentifier("restoredNote")
            }
            HStack {
                StatCell(value: Format.km(recorder.distanceMeters), unit: "km", size: 28)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("liveDistance")
                StatCell(value: Format.pace(recorder.paceNow), unit: "/km now", size: 28)
                StatCell(value: recorder.cadence.map { String(Int($0.rounded())) } ?? "--", unit: "steps/min", size: 28)
            }
            .padding(.top, 14)
            HStack(spacing: 10) {
                Button {
                    if recorder.state == .paused { recorder.resume() } else { recorder.pause() }
                } label: {
                    Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16)).foregroundStyle(Theme.paper)
                        .frame(width: 52, height: 52)
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        .contentShape(Circle())
                }
                .accessibilityIdentifier(recorder.state == .paused ? "resumeButton" : "pauseButton")
                HoldToStopButton { stop() }
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(Theme.ink).ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 26) }
        )
    }

    private func stop() {
        guard !saving else { return }
        saving = true
        let result = recorder.finish()
        Task {
            let w = await WorkoutStore.save(result, in: ctx, usePlaces: usePlaces,
                                            saveToHealth: saveToHealth && LaunchOptions.healthAllowed)
            // Only now is the workout safe; until here a relaunch can still restore it.
            recorder.draftStore?.clear()
            onSaved(w)
        }
    }
}

/// Press and hold for 0.85 s. Fills with accent left to right, then stops.
struct HoldToStopButton: View {
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var hint = false
    @State private var done = false
    static let duration = 0.85

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Capsule().fill(Theme.surface2)
                GeometryReader { g in
                    Rectangle().fill(Theme.accent).frame(width: g.size.width * progress)
                }
                .clipShape(Capsule())
                Text("Hold to stop").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.paper)
            }
            .frame(height: 52)
            .overlay(Capsule().strokeBorder(hint ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: Self.duration, maximumDistance: 40) {
                guard !done else { return }
                done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                action()
            } onPressingChanged: { pressing in
                holding = pressing
                if pressing {
                    hint = false
                    withAnimation(.linear(duration: Self.duration)) { progress = 1 }
                } else if !done {
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                    hint = true
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Hold to stop")
            .accessibilityIdentifier("holdToStop")
            if hint {
                Text("Keep holding. It saves the moment the bar fills.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    .transition(.opacity)
            }
        }
    }
}

/// Live map in strict greyscale. The accent position dot sits above it so it keeps its colour.
/// Its own view so camera ticks only re-render the map, not the controls.
struct LiveMonoMap: View {
    let recorder: WorkoutRecorder
    @Binding var camera: MapCameraPosition
    @State private var cameraTick = 0

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                RouteOverlay(pieces: RoutePieces.byModes(recorder.liveRoute, modes: recorder.liveModes), width: 4)
            }
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControlVisibility(.hidden)
            .saturation(0)
            .onMapCameraChange(frequency: .continuous) { cameraTick &+= 1 }
            .overlay {
                let _ = cameraTick
                if let last = recorder.liveRoute.last,
                   let p = proxy.convert(CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon), to: .local) {
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.25)).frame(width: 22, height: 22)
                        Circle().fill(Theme.accent).frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2))
                    }
                    .position(p)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}
