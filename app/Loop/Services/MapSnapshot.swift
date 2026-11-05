import UIKit
import MapKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// A strictly greyscale map image plus a projector that places coordinates on it.
struct MapSnap {
    let image: UIImage
    let project: (CLLocationCoordinate2D) -> CGPoint
}

/// Monochrome map snapshots for cards and the summary. Async, cached in memory, never blocks saving.
@MainActor
enum MapSnapshot {
    private static var cache: [String: MapSnap] = [:]

    /// - Parameters:
    ///   - routeBox: where the route should sit inside `size` (defaults to the whole size).
    static func make(id: UUID, route: [RoutePoint], size: CGSize, routeBox: CGRect? = nil,
                     scale: CGFloat = 3, timeout: Double = 10) async -> MapSnap? {
        guard route.count > 1, size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return nil }
        let box = routeBox ?? CGRect(origin: .zero, size: size)
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width >= 1, box.height >= 1 else { return nil }
        let key = "\(id)-\(Int(size.width))x\(Int(size.height))-\(Int(box.minX)),\(Int(box.minY)),\(Int(box.width)),\(Int(box.height))-\(scale)"
        if let hit = cache[key] { return hit }

        let options = MKMapSnapshotter.Options()
        options.mapRect = mapRect(route: route, size: size, box: box)
        options.size = size
        options.scale = scale
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = config
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        let snapshotter = MKMapSnapshotter(options: options)
        let snap: MKMapSnapshotter.Snapshot? = await withTaskGroup(of: MKMapSnapshotter.Snapshot?.self) { group in
            group.addTask { try? await snapshotter.start() }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { snapshotter.cancel() }
            return first
        }
        guard let snap, let grey = greyscale(snap.image) else { return nil }
        let result = MapSnap(image: grey, project: { snap.point(for: $0) })
        cache[key] = result
        return result
    }

    /// The map rect that puts the route (padded 25%) inside `box`, covering all of `size`.
    nonisolated static func mapRect(route: [RoutePoint], size: CGSize, box: CGRect) -> MKMapRect {
        let mps = route.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)) }
        var r = MKMapRect(origin: mps[0], size: MKMapSize(width: 0, height: 0))
        for p in mps { r = r.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
        let minSpan = 600 * MKMapPointsPerMeterAtLatitude(route[0].lat)
        let w = max(r.size.width, minSpan) * 1.25, h = max(r.size.height, minSpan) * 1.25
        // map points per view point
        let k = max(w / Double(box.width), h / Double(box.height))
        let cx = r.midX - (Double(box.midX)) * k, cy = r.midY - (Double(box.midY)) * k
        return MKMapRect(x: cx, y: cy, width: Double(size.width) * k, height: Double(size.height) * k)
    }


    /// Strict greyscale, a little darker with more contrast so it reads as dark grey.
    nonisolated static func greyscale(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let f = CIFilter.colorControls()
        f.inputImage = input
        f.saturation = 0
        f.brightness = 0.03
        f.contrast = 1.18
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }
}
