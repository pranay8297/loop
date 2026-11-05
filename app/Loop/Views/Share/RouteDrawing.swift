import SwiftUI
import CoreLocation

/// Pure route projection for cards: equirectangular with cos(mid-latitude) x-scaling,
/// aspect preserved, centred in the rect with padding.
enum RouteProjection {
    static func project(_ coords: [CLLocationCoordinate2D], into rect: CGRect, padding: CGFloat = 0) -> [CGPoint] {
        guard !coords.isEmpty else { return [] }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        let k = cos((minLat + maxLat) / 2 * .pi / 180)
        let dx = (maxLon - minLon) * k, dy = maxLat - minLat
        let inner = rect.insetBy(dx: padding, dy: padding)
        let sx = dx > 0 ? Double(inner.width) / dx : .infinity
        let sy = dy > 0 ? Double(inner.height) / dy : .infinity
        var s = min(sx, sy)
        if !s.isFinite { s = 0 }
        let w = dx * s, h = dy * s
        let ox = Double(inner.midX) - w / 2, oy = Double(inner.midY) - h / 2
        return coords.map { c in
            CGPoint(x: ox + (c.longitude - minLon) * k * s, y: oy + (maxLat - c.latitude) * s)
        }
    }
}

/// One drawable run or walk stretch in view coordinates.
struct DrawnPiece {
    let kind: MoveKind
    let points: [CGPoint]
}

/// Route pieces for a card. With `hide` on, the first and last 200 m are dropped first.
enum CardRoute {
    static func points(_ route: [RoutePoint], hide: Bool) -> [RoutePoint] {
        hide ? RouteTrimmer.trim(route) : route
    }
    static func pieces(_ route: [RoutePoint], segments: [MoveSegment], hide: Bool) -> [RoutePiece] {
        let pts = points(route, hide: hide)
        guard pts.count > 1 else { return [] }
        return RoutePieces.bySegments(pts, segments: segments)
    }
}

/// Draws pieces (already in view coordinates): run solid, walk dotted, accent finish dot.
struct RouteInk: View {
    let pieces: [DrawnPiece]
    var color: Color = Theme.paper
    var width: CGFloat = 4
    var showFinish = true
    var shadow = false

    var body: some View {
        Canvas { ctx, _ in
            if shadow { ctx.addFilter(.shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1.5)) }
            for piece in pieces where piece.points.count > 1 {
                var path = Path()
                path.addLines(piece.points)
                if piece.kind == .run {
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                } else {
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width * 1.1, lineCap: .round, dash: [0, 2.3 * width]))
                }
            }
            if showFinish, let end = pieces.last?.points.last {
                let r = width * 1.4
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r)), with: .color(Theme.accent))
            }
        }
        .allowsHitTesting(false)
    }

    /// Fits route pieces into `rect` with the pure projection.
    static func fitted(_ pieces: [RoutePiece], in rect: CGRect, padding: CGFloat = 0) -> [DrawnPiece] {
        let all = pieces.flatMap(\.coords)
        let pts = RouteProjection.project(all, into: rect, padding: padding)
        var out: [DrawnPiece] = []
        var i = 0
        for p in pieces {
            out.append(DrawnPiece(kind: p.kind, points: Array(pts[i..<i + p.coords.count])))
            i += p.coords.count
        }
        return out
    }

    /// Positions route pieces with a projector (e.g. a map snapshot's point(for:)).
    static func projected(_ pieces: [RoutePiece], with project: (CLLocationCoordinate2D) -> CGPoint) -> [DrawnPiece] {
        pieces.map { DrawnPiece(kind: $0.kind, points: $0.coords.map(project)) }
    }
}

/// The loop mark: one line that loops over itself, ending in an accent dot.
struct LoopMark: View {
    var color: Color = Theme.paper
    var size: CGFloat = 24

    static let raw: [CGPoint] = stride(from: -3.5, through: 3.4001, by: 0.035).map { t in
        CGPoint(x: t - 2.6 * sin(t), y: -2.6 * cos(t))
    }

    var body: some View {
        Canvas { ctx, sz in
            let xs = Self.raw.map(\.x), ys = Self.raw.map(\.y)
            let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
            let pad = sz.width * 3 / 64
            let sc = (sz.width - 2 * pad) / max(w, h)
            let ox = (sz.width - w * sc) / 2, oy = (sz.height - h * sc) / 2
            let pts = Self.raw.map { CGPoint(x: ox + ($0.x - xs.min()!) * sc, y: oy + ($0.y - ys.min()!) * sc) }
            let sw = sz.width * 5.2 / 64
            var gone: CGFloat = 0, e = pts.count - 1
            while e > 1, gone < sw * 1.7 { gone += hypot(pts[e].x - pts[e - 1].x, pts[e].y - pts[e - 1].y); e -= 1 }
            var path = Path(); path.addLines(Array(pts[0...e]))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))
            let end = pts.last!, r = sw * 0.8
            ctx.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r)), with: .color(Theme.accent))
        }
        .frame(width: size, height: size)
    }
}

/// Mark plus "loop" wordmark.
struct LoopWordmark: View {
    var color: Color = Theme.paper
    var size: CGFloat = 16
    var body: some View {
        HStack(spacing: size * 0.32) {
            LoopMark(color: color, size: size * 1.5)
            Text("loop").font(.system(size: size, weight: .semibold)).tracking(-size * 0.05).foregroundStyle(color)
        }
    }
}
