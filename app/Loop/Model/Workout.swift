import Foundation
import SwiftData

@Model
final class Workout {
    var id: UUID = UUID()
    var kindRaw: String = ActivityKind.run.rawValue
    var startDate: Date = Date()
    var endDate: Date = Date()
    var movingSeconds: Double = 0
    var distanceMeters: Double = 0
    var name: String = ""
    var nameReason: String = ""
    /// True once the user renamed it; the namer then leaves the name alone.
    var userRenamed: Bool = false
    var isCheckIn: Bool = false
    var steps: Int?
    @Attribute(.externalStorage) var routeData: Data?
    var segmentsData: Data?
    var healthKitID: UUID?
    var placeName: String?
    var cityName: String?

    init(kind: ActivityKind, startDate: Date, endDate: Date, movingSeconds: Double,
         distanceMeters: Double, name: String = "", nameReason: String = "", isCheckIn: Bool = false,
         steps: Int? = nil, route: [RoutePoint] = [], segments: [MoveSegment] = []) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.movingSeconds = movingSeconds
        self.distanceMeters = distanceMeters
        self.name = name
        self.nameReason = nameReason
        self.isCheckIn = isCheckIn
        self.steps = steps
        self.routeData = route.isEmpty ? nil : try? JSONEncoder().encode(route)
        self.segmentsData = segments.isEmpty ? nil : try? JSONEncoder().encode(segments)
    }

    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .run }

    var route: [RoutePoint] {
        guard let routeData else { return [] }
        return (try? JSONDecoder().decode([RoutePoint].self, from: routeData)) ?? []
    }
    var segments: [MoveSegment] {
        guard let segmentsData else { return [] }
        return (try? JSONDecoder().decode([MoveSegment].self, from: segmentsData)) ?? []
    }
    var runMeters: Double { segments.filter { $0.kind == .run }.reduce(0) { $0 + $1.meters } }
    var walkMeters: Double { segments.filter { $0.kind == .walk }.reduce(0) { $0 + $1.meters } }
    var walkStretches: Int { segments.filter { $0.kind == .walk }.count }

    /// Seconds per km over moving time.
    var avgPace: Double? {
        guard distanceMeters >= 50, movingSeconds > 0 else { return nil }
        return movingSeconds / (distanceMeters / 1000)
    }
    /// Seconds per km over run segments only.
    var runningPace: Double? {
        let runs = segments.filter { $0.kind == .run }
        let m = runs.reduce(0) { $0 + $1.meters }
        let s = runs.reduce(0) { $0 + $1.endTime.timeIntervalSince($1.startTime) }
        guard m >= 50, s > 0 else { return nil }
        return s / (m / 1000)
    }
    var runFraction: Double? {
        let total = runMeters + walkMeters
        guard total > 0 else { return nil }
        return runMeters / total
    }
    var durationSeconds: Double { isCheckIn ? endDate.timeIntervalSince(startDate) : movingSeconds }
}
