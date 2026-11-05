import Foundation

enum PermissionState: Sendable, Equatable { case notDetermined, denied, restricted, authorized }

struct DeviceEnvironment: Sendable, Equatable {
    var locationServicesEnabled: Bool
    var locationAuth: PermissionState
    var motionAvailable: Bool
    var pedometerAvailable: Bool
    var motionAuth: PermissionState
    var watchPaired: Bool

    static let allGood = DeviceEnvironment(locationServicesEnabled: true, locationAuth: .authorized,
                                           motionAvailable: true, pedometerAvailable: true,
                                           motionAuth: .authorized, watchPaired: false)
}

enum CapabilityAction: Sendable, Equatable { case checkIn, openSettings }

enum Capability: Sendable, Equatable {
    case track(note: String)
    case trackLimited(note: String)
    case cannotTrack(title: String, detail: String, actions: [CapabilityAction])

    var canTrack: Bool {
        if case .cannotTrack = self { return false }
        return true
    }
}

enum CapabilityChecker {
    static func decide(kind: ActivityKind, env: DeviceEnvironment) -> Capability {
        switch kind {
        case .run, .walk, .ride:
            let locationBlocked = !env.locationServicesEnabled
                || env.locationAuth == .denied || env.locationAuth == .restricted
            if locationBlocked {
                return .cannotTrack(
                    title: "Location is off for Loop",
                    detail: "Loop needs your location to map the route and measure distance. Turn it on in Settings, or check in instead.",
                    actions: [.openSettings, .checkIn])
            }
            if kind == .run {
                let motionOff = !env.motionAvailable || env.motionAuth == .denied || env.motionAuth == .restricted
                if motionOff {
                    return .trackLimited(note: "Route and pace are ready. Walk breaks need Motion & Fitness, which is off.")
                }
                return .track(note: "iPhone GPS and motion ready. Walk breaks are picked up on their own.")
            }
            if kind == .walk { return .track(note: "iPhone GPS and motion ready.") }
            return .track(note: "iPhone GPS ready.")
        case .swim:
            if env.watchPaired {
                return .cannotTrack(
                    title: "Start it on your Apple Watch",
                    detail: "Record a Pool Swim in the Workout app on your Watch. Loop will pick swims up from Apple Health in a later version. For now, check in.",
                    actions: [.checkIn])
            }
            return .cannotTrack(
                title: "Apple Watch not connected",
                detail: "Your iPhone can't track a swim, so Loop can't count lengths or distance. You can still check in.",
                actions: [.checkIn])
        case .gym:
            if env.watchPaired {
                return .cannotTrack(
                    title: "Start it on your Apple Watch",
                    detail: "Record a strength workout in the Workout app on your Watch. Loop will pick it up from Apple Health in a later version. For now, check in.",
                    actions: [.checkIn])
            }
            return .cannotTrack(
                title: "Apple Watch not connected",
                detail: "Your iPhone can't measure heart rate or effort in the gym. You can still check in.",
                actions: [.checkIn])
        }
    }
}
