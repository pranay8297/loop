import Foundation

enum ActivityKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case run, walk, ride, swim, gym
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .run: "Run"
        case .walk: "Walk"
        case .ride: "Ride"
        case .swim: "Swim"
        case .gym: "Gym"
        }
    }
    var symbol: String {
        switch self {
        case .run: "figure.run"
        case .walk: "figure.walk"
        case .ride: "figure.outdoor.cycle"
        case .swim: "figure.pool.swim"
        case .gym: "dumbbell"
        }
    }
    /// Sub-label under the Start button.
    var startSubtitle: String {
        switch self {
        case .run: "run or run-walk"
        case .walk: "walk"
        case .ride: "ride"
        case .swim: "swim"
        case .gym: "gym"
        }
    }
    var checkInTitle: String {
        switch self {
        case .swim: "Pool swim"
        case .gym: "Gym session"
        case .run: "Run"
        case .walk: "Walk"
        case .ride: "Ride"
        }
    }
    /// Lowercase noun used in check-in names and toasts.
    var noun: String { rawValue }
    var isGPS: Bool { self == .run || self == .walk || self == .ride }
}

struct RoutePoint: Codable, Sendable, Equatable {
    var lat: Double
    var lon: Double
    var alt: Double
    var t: Date
    /// m/s, -1 when invalid
    var speed: Double
    var hAcc: Double
    /// Cumulative moving distance up to this point.
    var cumMeters: Double
    /// True when the interval leading to this point is not moving time
    /// (recorded while paused, or the first fix after a resume).
    var paused: Bool?

    var isPaused: Bool { paused == true }
}

enum MoveKind: String, Codable, Sendable { case run, walk }

struct MoveSegment: Codable, Sendable, Equatable {
    var kind: MoveKind
    var startMeters: Double
    var endMeters: Double
    var startTime: Date
    var endTime: Date
    var meters: Double { max(0, endMeters - startMeters) }
}
