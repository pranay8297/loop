import Foundation
import CoreLocation

struct ResolvedPlace: Sendable, Equatable { var place: String?; var city: String? }

/// Reverse-geocodes route points. The only network use in the app.
enum PlaceResolver {
    struct Mark: Sendable { var areaOfInterest: String?; var subLocality: String?; var locality: String? }

    /// Pure choice between the midpoint and the far point. Tested.
    static func choose(mid: Mark?, far: Mark?) -> ResolvedPlace {
        guard let mid else { return ResolvedPlace(place: nil, city: nil) }
        let raw: String?
        if let a = mid.areaOfInterest, !a.isEmpty { raw = a }
        else if let a = mid.subLocality, let b = far?.subLocality, a == b { raw = a }
        else if let a = mid.subLocality { raw = a }
        else { raw = mid.locality }
        return ResolvedPlace(place: RuleBasedNamer.cleanPlace(raw), city: mid.locality)
    }

    static func mark(lat: Double, lon: Double) async -> Mark? {
        let geocoder = CLGeocoder()
        guard let p = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)).first else { return nil }
        return Mark(areaOfInterest: p.areasOfInterest?.first, subLocality: p.subLocality, locality: p.locality)
    }

    static func resolve(route: [RoutePoint]) async -> ResolvedPlace? {
        guard let mid = RouteGeometry.midpoint(route) else { return nil }
        guard let m = await mark(lat: mid.lat, lon: mid.lon) else { return nil }
        var f: Mark?
        if let far = RouteGeometry.farthestFromStart(route) { f = await mark(lat: far.lat, lon: far.lon) }
        return choose(mid: m, far: f)
    }

    static func resolve(location: CLLocation) async -> ResolvedPlace? {
        guard let m = await mark(lat: location.coordinate.latitude, lon: location.coordinate.longitude) else { return nil }
        return choose(mid: m, far: nil)
    }
}
