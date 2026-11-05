import Foundation
import CoreLocation
import CoreMotion
import WatchConnectivity
import Observation

/// Reads the live device environment. Re-evaluated on foreground and after permission changes.
@MainActor
@Observable
final class DeviceEnvironmentProvider: NSObject {
    private(set) var env: DeviceEnvironment = .allGood
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var watchDelegate: WatchDelegate?
    @ObservationIgnored private var watchPaired = false
    @ObservationIgnored private let forceReady: Bool

    init(forceReady: Bool = false) {
        self.forceReady = forceReady
        super.init()
        manager.delegate = self
        if WCSession.isSupported() {
            let d = WatchDelegate { [weak self] paired in
                Task { @MainActor in self?.watchPaired = paired; self?.refresh() }
            }
            watchDelegate = d
            WCSession.default.delegate = d
            WCSession.default.activate()
        }
        refresh()
    }

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }

    var lastKnownLocation: CLLocation? { manager.location }

    func refresh() {
        if forceReady {
            env = DeviceEnvironment(locationServicesEnabled: true, locationAuth: .authorized, motionAvailable: true,
                                    pedometerAvailable: true, motionAuth: .authorized, watchPaired: false)
            return
        }
        let loc: PermissionState = switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        default: .authorized
        }
        let motion: PermissionState = switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        default: .authorized
        }
        let servicesOn = loc == .denied ? CLLocationManager.locationServicesEnabled() : true
        env = DeviceEnvironment(
            locationServicesEnabled: servicesOn,
            locationAuth: loc,
            motionAvailable: CMMotionActivityManager.isActivityAvailable(),
            pedometerAvailable: CMPedometer.isStepCountingAvailable(),
            motionAuth: motion,
            watchPaired: watchPaired)
    }
}

extension DeviceEnvironmentProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
}

private final class WatchDelegate: NSObject, WCSessionDelegate {
    let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        onChange(activationState == .activated && session.isPaired)
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) { onChange(session.isPaired) }
}
