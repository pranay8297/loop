import Foundation
import SwiftData
import CoreLocation

/// Saves workouts locally first, then improves the name with a place and writes to Health.
@MainActor
enum WorkoutStore {
    static var namer: WorkoutNamer = RuleBasedNamer()

    static func digests(_ ctx: ModelContext, excluding id: UUID? = nil) -> [WorkoutDigest] {
        let all = (try? ctx.fetch(FetchDescriptor<Workout>())) ?? []
        return all.filter { $0.id != id }.map {
            WorkoutDigest(kind: $0.kind, distanceMeters: $0.distanceMeters,
                          fastestKm: $0.kind == .run ? SplitsCalculator.fastestKmSeconds($0.route) : nil,
                          hadWalk: $0.walkMeters > 0, isCheckIn: $0.isCheckIn)
        }
    }

    static func highlights(for w: Workout, history: [WorkoutDigest]) -> [Highlight] {
        let digest = WorkoutDigest(kind: w.kind, distanceMeters: w.distanceMeters,
                                   fastestKm: w.kind == .run ? SplitsCalculator.fastestKmSeconds(w.route) : nil,
                                   hadWalk: w.walkMeters > 0, isCheckIn: w.isCheckIn)
        return Highlights.compute(current: digest, runFraction: w.runFraction, history: history)
    }

    static func namingInput(for w: Workout, history: [WorkoutDigest], place: String?) -> NamingInput {
        let route = w.route
        let anchor = route.first
        return NamingInput(start: w.startDate, timeZone: .current, latitude: anchor?.lat, longitude: anchor?.lon,
                           place: place, shape: RouteGeometry.shape(route), kind: w.kind,
                           hasWalkSegments: w.walkMeters > 0,
                           highlights: highlights(for: w, history: history), isCheckIn: w.isCheckIn)
    }

    /// Saves immediately. Place name and Health happen afterwards and never block the save.
    @discardableResult
    static func save(_ r: RecordingResult, in ctx: ModelContext, usePlaces: Bool, saveToHealth: Bool) async -> Workout {
        let history = digests(ctx)
        let w = Workout(kind: r.kind, startDate: r.start, endDate: r.end, movingSeconds: r.movingSeconds,
                        distanceMeters: r.distanceMeters, steps: r.steps, route: r.route, segments: r.segments)
        let named = await namer.name(for: namingInput(for: w, history: history, place: nil))
        w.name = named.name; w.nameReason = named.reason
        ctx.insert(w)
        removeDetected(overlapping: r.start, r.end, in: ctx)
        try? ctx.save()

        let route = r.route
        Task { @MainActor in
            if usePlaces, !route.isEmpty, let resolved = await PlaceResolver.resolve(route: route) {
                w.placeName = resolved.place
                w.cityName = resolved.city
                if !w.userRenamed, resolved.place != nil {
                    let better = await namer.name(for: namingInput(for: w, history: history, place: resolved.place))
                    w.name = better.name; w.nameReason = better.reason
                }
                try? ctx.save()
            }
        }
        if saveToHealth {
            Task { @MainActor in
                if let id = await HealthService.shared.save(kind: r.kind, start: r.start, end: r.end,
                                                             distanceMeters: r.distanceMeters, route: route) {
                    w.healthKitID = id
                    try? ctx.save()
                }
            }
        }
        return w
    }

    /// A recording always wins: workouts picked up from motion history that overlap it go.
    static func removeDetected(overlapping start: Date, _ end: Date, in ctx: ModelContext) {
        let motion = (try? ctx.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.source == "motion" }))) ?? []
        for d in motion where MotionHistory.overlap(start, end, d.startDate, d.endDate) >= MotionHistory.minOverlap {
            ctx.delete(d)
        }
    }

    static func checkIn(kind: ActivityKind, minutes: Int, earlier: Bool, in ctx: ModelContext,
                        lastKnown: CLLocation?, usePlaces: Bool) async -> Workout {
        let end = earlier ? Date().addingTimeInterval(-2 * 3600) : Date()
        let start = end.addingTimeInterval(-Double(minutes) * 60)
        let w = Workout(kind: kind, startDate: start, endDate: end, movingSeconds: Double(minutes) * 60,
                        distanceMeters: 0, isCheckIn: true)
        var input = NamingInput(start: start, timeZone: .current, latitude: lastKnown?.coordinate.latitude,
                                longitude: lastKnown?.coordinate.longitude, place: nil, shape: .pointToPoint,
                                kind: kind, hasWalkSegments: false, highlights: [], isCheckIn: true)
        let first = await namer.name(for: input)
        w.name = first.name; w.nameReason = "Checked in on your iPhone. It counts toward your week."
        ctx.insert(w)
        try? ctx.save()
        if usePlaces, let loc = lastKnown {
            Task { @MainActor in
                if let r = await PlaceResolver.resolve(location: loc), r.place != nil {
                    w.placeName = r.place; w.cityName = r.city
                    input.place = r.place
                    if !w.userRenamed { w.name = await namer.name(for: input).name }
                    try? ctx.save()
                }
            }
        }
        return w
    }
}
