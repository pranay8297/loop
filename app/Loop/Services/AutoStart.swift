import Foundation
import CoreLocation
import Observation
import UIKit

/// Notices when he heads out and starts a recording by itself. While waiting it uses only a ~150 m
/// geofence (CLMonitor) and significant location changes: no GPS until he is actually moving.
/// Needs location Always. Off by default.
@MainActor
@Observable
final class AutoStart: NSObject {
    static let enabledKey = "autoStart"
    static let askDoneKey = "autoStartAskDone"
    static let monitorName = "LoopAutoStart"
    static let regionID = "settled"
    static let radius: CLLocationDistance = 150

    static let shared = AutoStart()

    private(set) var auth: CLAuthorizationStatus = .notDetermined
    var isAlways: Bool { auth == .authorizedAlways }
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    @ObservationIgnored weak var session: Session?
    @ObservationIgnored var history: MotionHistoryProvider = LiveMotionHistory()
    @ObservationIgnored var log: PowerLog? = PowerLog.shared
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var evaluating = false
    @ObservationIgnored private var authWaiters: [CheckedContinuation<Void, Never>] = []

    override private init() {
        super.init()
        manager.delegate = self
        // One-shot fixes for arming only: cheap Wi-Fi/cell accuracy is enough for a 150 m circle.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        auth = manager.authorizationStatus
    }

    /// Called from `LoopApp.init`, before any view: after a background launch by Core Location the
    /// monitor must be re-created with the same name at once so its events arrive.
    func boot(session: Session) {
        self.session = session
        auth = manager.authorizationStatus
        refresh(armNow: false)
        // Arm at launch only when opened by him. A background launch is a wake; its event re-arms.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.watching, UIApplication.shared.applicationState != .background,
                  self.session?.recorder == nil else { return }
            self.arm(at: self.manager.location)
        }
    }

    /// Starts or stops watching to match the setting and permission.
    func refresh(armNow: Bool = true) {
        if enabled && isAlways { startWatching(armNow: armNow) } else { stopWatching() }
    }

    func setEnabled(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { await requestAlways() }
        refresh()
    }

    /// When In Use first if needed, then Always. Each step waits for the answer (or gives up after 30 s,
    /// since iOS shows the Always prompt only once).
    func requestAlways() async {
        if auth == .notDetermined {
            manager.requestWhenInUseAuthorization()
            await waitForAuthChange()
        }
        if auth == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
            await waitForAuthChange()
        }
    }

    private func waitForAuthChange() async {
        await withCheckedContinuation { c in
            authWaiters.append(c)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.resumeWaiters()
            }
        }
    }

    private func resumeWaiters() {
        let w = authWaiters; authWaiters.removeAll()
        w.forEach { $0.resume() }
    }

    // MARK: watching

    private func startWatching(armNow: Bool) {
        manager.startMonitoringSignificantLocationChanges()
        guard !watching else { if armNow, session?.recorder == nil { arm(at: manager.location) }; return }
        watching = true
        monitorTask = Task { [weak self] in
            let m = await CLMonitor(Self.monitorName)
            await MainActor.run { self?.monitor = m }
            if armNow { await MainActor.run { if self?.session?.recorder == nil { self?.arm(at: self?.manager.location) } } }
            do {
                for try await e in await m.events {
                    if Task.isCancelled { break }
                    let state = switch e.state {
                    case .satisfied: "satisfied"
                    case .unsatisfied: "unsatisfied"
                    default: "unknown"
                    }
                    await MainActor.run { self?.log?.log(.geofence, reason: "event: \(state)") }
                    if e.state == .unsatisfied { await self?.wake(reason: "left the area", at: nil) }
                }
            } catch {}
        }
    }

    private func stopWatching() {
        guard watching else { manager.stopMonitoringSignificantLocationChanges(); return }
        watching = false
        manager.stopMonitoringSignificantLocationChanges()
        monitorTask?.cancel(); monitorTask = nil
        if let m = monitor { Task { await m.remove(Self.regionID) } }
        monitor = nil
    }

    /// A location older than this is not where he is now.
    static let maxFixAge: TimeInterval = 60

    /// `requestLocation()` at most this often; a suppressed request waits for the next wake.
    static let minRequestGap: TimeInterval = 120
    @ObservationIgnored private var lastFixRequest: Date?

    enum ArmAction: Equatable { case arm(lat: Double, lon: Double), requestFix, nothing }

    /// Pure. A `delivered` location (from `didUpdateLocations`) is the freshest the system has: arm at
    /// it whatever its age. A fallback (`manager.location`, or none) arms only when fresh; otherwise it
    /// asks for one fix, at most once per `minRequestGap`.
    static func armAction(for loc: CLLocation?, delivered: Bool, now: Date, lastRequest: Date?) -> ArmAction {
        if let loc, loc.horizontalAccuracy >= 0, delivered || now.timeIntervalSince(loc.timestamp) <= maxFixAge {
            return .arm(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        }
        if let l = lastRequest, now.timeIntervalSince(l) <= minRequestGap { return .nothing }
        return .requestFix
    }

    /// Draws the ~150 m circle around where he is now (settled). Never at a stale fallback position.
    func arm(at loc: CLLocation?, delivered: Bool = false) {
        guard watching, let m = monitor else { return }
        let now = Date()
        switch Self.armAction(for: loc, delivered: delivered, now: now, lastRequest: lastFixRequest) {
        case .arm: break
        case .requestFix:
            lastFixRequest = now
            log?.log(.geofence, reason: "fix requested")
            manager.requestLocation()
            return
        case .nothing:
            log?.log(.geofence, reason: "fix request suppressed")
            return
        }
        guard let loc else { return }
        log?.log(.geofence, reason: "armed: \(Int(loc.horizontalAccuracy.rounded())) m, \(Int(now.timeIntervalSince(loc.timestamp).rounded())) s old")
        let cond = CLMonitor.CircularGeographicCondition(center: loc.coordinate, radius: Self.radius)
        Task {
            await m.remove(Self.regionID)
            await m.add(cond, identifier: Self.regionID, assuming: .satisfied)
        }
    }

    /// After an auto recording ends, or when he stopped without moving off.
    func armHere() { arm(at: manager.location) }

    // MARK: wake

    /// A low-power wake: read the last 10 minutes of motion and decide.
    func wake(reason: String, at loc: CLLocation?, now: Date = Date()) async {
        log?.log(.wake, reason: reason)
        guard let session else { return }
        if evaluating {
            // Busy with another wake: still keep the circle armed at a fresh position.
            if session.recorder == nil, let loc { arm(at: loc, delivered: true) }
            return
        }
        if let r = session.recorder {
            // A quiet auto recording (the app was suspended) closes now; autoFinish re-arms.
            if r.isAuto { r.checkAutoStop() }
            log?.log(.wakeIgnored, reason: "already recording")
            return
        }
        evaluating = true; defer { evaluating = false }
        let samples = await history.activities(from: now.addingTimeInterval(-AutoStartPolicy.window), to: now)
        switch AutoStartPolicy.decide(samples, now: now, recording: session.recorder != nil) {
        case .start(let kind, let from):
            let p = kind == .ride ? nil : await history.pedometer(from: from, to: now)
            let pre = AutoStartPolicy.preroll(from: from, to: now, steps: p?.steps ?? 0, meters: p?.distance)
            let mins = Int(now.timeIntervalSince(from) / 60)
            log?.log(.autoStart, reason: "\(kind == .ride ? "ride" : "on foot"), began \(mins) min ago")
            session.beginAuto(kind: kind, from: from, preroll: pre)
        case .ignore(let why):
            log?.log(.wakeIgnored, reason: why)
            if let loc { arm(at: loc, delivered: true) } else { arm(at: manager.location) }
        }
    }
}

extension AutoStart: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.auth = s
            self.resumeWaiters()
            // iOS calls this on every launch, also a background launch by the geofence exit:
            // arming then could swallow that pending event. Only a handled wake re-arms.
            self.refresh(armNow: UIApplication.shared.applicationState != .background)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in
            guard self.watching else { return }
            await self.wake(reason: "location changed", at: last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

#if DEBUG
/// `-LoopFakeWake walk|run|ride`: the last `minutes` of motion history show that movement.
final class FakeWakeHistory: MotionHistoryProvider {
    let kind: ActivityHistorySample.Kind
    let minutes: Double
    init(kind: ActivityHistorySample.Kind, minutes: Double) { self.kind = kind; self.minutes = minutes }
    var isAuthorized: Bool { true }
    func activities(from: Date, to: Date) async -> [ActivityHistorySample] {
        [.init(start: to.addingTimeInterval(-minutes * 60 - 60), kind: .stationary, confidence: .high),
         .init(start: to.addingTimeInterval(-minutes * 60), kind: kind, confidence: .high)]
    }
    func pedometer(from: Date, to: Date) async -> (steps: Int, distance: Double?, floors: Int?)? {
        let mins = to.timeIntervalSince(from) / 60
        return (Int(mins * 110), mins * 85, nil)
    }
}
#endif
