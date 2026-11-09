import Foundation
import HealthKit
import CoreLocation
import os

/// Writes finished workouts to Apple Health. Never reads.
@MainActor
final class HealthService {
    static let shared = HealthService()
    private let store = HKHealthStore()
    private let log = Logger(subsystem: "com.pranaybindela.loop", category: "health")

    private var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
         HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling)]
    }

    /// Deletes one of Loop's own Health workouts by its UUID. Returns true when it is gone.
    @discardableResult
    func delete(id: UUID) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            let query = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: id))], sortDescriptors: [])
            let found = try await query.result(for: store)
            guard !found.isEmpty else { return true }
            try await store.delete(found)
            return true
        } catch {
            log.error("HealthKit delete failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Returns the HealthKit workout UUID, or nil on any failure.
    func save(kind: ActivityKind, start: Date, end: Date, distanceMeters: Double, route: [RoutePoint]) async -> UUID? {
        guard HKHealthStore.isHealthDataAvailable(), kind.isGPS else { return nil }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: [])
            let config = HKWorkoutConfiguration()
            config.activityType = switch kind {
            case .walk: .walking
            case .ride: .cycling
            default: .running
            }
            config.locationType = .outdoor
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            try await builder.beginCollection(at: start)
            if distanceMeters > 0 {
                let type = HKQuantityType(kind == .ride ? .distanceCycling : .distanceWalkingRunning)
                let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .meter(), doubleValue: distanceMeters),
                                              start: start, end: end)
                try await builder.addSamples([sample])
            }
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else { return nil }
            let locations = route.filter { !$0.isPaused }.map {
                CLLocation(coordinate: .init(latitude: $0.lat, longitude: $0.lon), altitude: $0.alt,
                           horizontalAccuracy: $0.hAcc, verticalAccuracy: -1, course: -1,
                           speed: $0.speed, timestamp: $0.t)
            }
            if !locations.isEmpty {
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
                try await routeBuilder.insertRouteData(locations)
                _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
            return workout.uuid
        } catch {
            log.error("HealthKit save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
