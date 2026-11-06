import SwiftUI
import MapKit
import CoreLocation

/// The quiet map behind the Start screen, made only of the user's own movement:
/// faint lines for every recorded route and a soft glow where they go most.
/// Static: no animation, no timers, no location updates, no network.
struct HomeMapBackground: View {
    /// Recorded routes, newest first.
    let routes: [[RoutePoint]]
    let heat: [PersonalHeat.Cell]
    let lastKnown: CLLocation?

    @State private var region: MKCoordinateRegion?

    private var center: CLLocationCoordinate2D? {
        if let l = lastKnown { return l.coordinate }
        guard let r = routes.first(where: { !$0.isEmpty }) else { return nil }
        let m = r[r.count / 2]
        return CLLocationCoordinate2D(latitude: m.lat, longitude: m.lon)
    }

    var body: some View {
        ZStack {
            Theme.ink
            if let c = center {
                Map(initialPosition: .camera(MapCamera(centerCoordinate: c, distance: 4000)), interactionModes: []) {}
                    .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                    .mapControlVisibility(.hidden)
                    .saturation(0)
                    .opacity(0.55)
                    .onMapCameraChange(frequency: .onEnd) { ctx in region = ctx.region }
                    .overlay {
                        if let region {
                            GeometryReader { geo in
                                let proj = Projection(region: region, size: geo.size)
                                Canvas { g, _ in draw(in: &g, proj: proj) }
                            }
                        }
                    }
                fade
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Ink at the top for the header and week card, clearest around Start, ink again by the tab bar.
    private var fade: some View {
        LinearGradient(stops: [
            .init(color: Theme.ink, location: 0),
            .init(color: Theme.ink, location: 0.30),
            .init(color: Theme.ink.opacity(0.35), location: 0.42),
            .init(color: Theme.ink.opacity(0.1), location: 0.55),
            .init(color: Theme.ink.opacity(0.4), location: 0.66),
            .init(color: Theme.ink.opacity(0.85), location: 0.8),
            .init(color: Theme.ink, location: 0.9),
        ], startPoint: .top, endPoint: .bottom)
    }

    private func draw(in g: inout GraphicsContext, proj: Projection) {
        for c in heat { glow(&g, proj: proj, cell: c) }
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        for r in routes where r.count > 1 {
            var path = Path()
            var started = false
            for p in r {
                let pt = proj.point(lat: p.lat, lon: p.lon)
                if started && p.paused != true { path.addLine(to: pt) } else { path.move(to: pt); started = true }
            }
            g.stroke(path, with: .color(Theme.paper.opacity(0.3)), style: style)
        }
    }

    /// One visit is barely there; streets used again and again glow brightest, up to a cap.
    static func opacity(_ n: Int) -> Double { min(0.7, 0.08 + 0.2 * log2(Double(max(n, 1)))) }

    private func glow(_ g: inout GraphicsContext, proj: Projection, cell: PersonalHeat.Cell) {
        guard let b = Geohash.bounds(cell.g) else { return }
        let a = proj.point(lat: b.n, lon: b.w), z = proj.point(lat: b.s, lon: b.e)
        let mid = CGPoint(x: (a.x + z.x) / 2, y: (a.y + z.y) / 2)
        let r = max(abs(z.x - a.x), abs(z.y - a.y)) * 1.2
        guard r > 0.5, mid.x > -r, mid.y > -r, mid.x < proj.size.width + r, mid.y < proj.size.height + r else { return }
        let o = Self.opacity(cell.n)
        let rect = CGRect(x: mid.x - r, y: mid.y - r, width: 2 * r, height: 2 * r)
        g.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [Theme.accent.opacity(o), Theme.accent.opacity(o * 0.35), Theme.accent.opacity(0)]),
            center: mid, startRadius: 0, endRadius: r))
    }
}

/// Web Mercator from a map region onto the map's frame.
struct Projection {
    let region: MKCoordinateRegion
    let size: CGSize

    private static func mercY(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }

    func point(lat: Double, lon: Double) -> CGPoint {
        let c = region.center, s = region.span
        let west = c.longitude - s.longitudeDelta / 2
        let n = Self.mercY(c.latitude + s.latitudeDelta / 2), so = Self.mercY(c.latitude - s.latitudeDelta / 2)
        let x = (lon - west) / s.longitudeDelta * size.width
        let y = (n - Self.mercY(lat)) / (n - so) * size.height
        return CGPoint(x: x, y: y)
    }
}
