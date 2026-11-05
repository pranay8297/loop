import SwiftUI
import MapKit

/// Run/walk/ride = filled dot, swim = ring, gym = small square.
struct DayMark: View {
    let kind: ActivityKind?
    var size: CGFloat = 8
    var body: some View {
        switch kind {
        case .none: EmptyView()
        case .swim?: Circle().strokeBorder(Theme.paper, lineWidth: 1.4).frame(width: size + 2, height: size + 2)
        case .gym?: Rectangle().fill(Theme.paper).frame(width: size - 1, height: size - 1)
        default: Circle().fill(Theme.paper).frame(width: size, height: size)
        }
    }
}

struct AccentDot: View {
    var size: CGFloat = 7
    var body: some View { Circle().fill(Theme.accent).frame(width: size, height: size) }
}

struct BlinkingDot: View {
    @State private var on = true
    var body: some View {
        AccentDot(size: 6).opacity(on ? 1 : 0.15)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = false } }
    }
}

/// Splits a route into contiguous pieces by kind for drawing.
struct RoutePiece: Identifiable {
    let id: Int
    let kind: MoveKind
    let coords: [CLLocationCoordinate2D]
}

enum RoutePieces {
    static func byModes(_ pts: [RoutePoint], modes: [MoveKind]) -> [RoutePiece] {
        guard !pts.isEmpty else { return [] }
        var out: [RoutePiece] = []
        var cur: [CLLocationCoordinate2D] = []
        var k = modes.first ?? .run
        for (i, p) in pts.enumerated() {
            let m = i < modes.count ? modes[i] : k
            let c = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
            if m != k {
                cur.append(c)
                out.append(RoutePiece(id: out.count, kind: k, coords: cur))
                cur = [c]; k = m
            } else { cur.append(c) }
        }
        out.append(RoutePiece(id: out.count, kind: k, coords: cur))
        return out
    }

    static func bySegments(_ pts: [RoutePoint], segments: [MoveSegment]) -> [RoutePiece] {
        guard !segments.isEmpty else { return byModes(pts, modes: Array(repeating: .run, count: pts.count)) }
        let modes: [MoveKind] = pts.map { p in
            segments.first(where: { p.cumMeters >= $0.startMeters && p.cumMeters <= $0.endMeters })?.kind ?? .run
        }
        return byModes(pts, modes: modes)
    }
}

struct RouteOverlay: MapContent {
    let pieces: [RoutePiece]
    var width: CGFloat = 4
    var body: some MapContent {
        ForEach(pieces) { piece in
            if piece.kind == .run {
                MapPolyline(coordinates: piece.coords)
                    .stroke(Theme.paper, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            } else {
                MapPolyline(coordinates: piece.coords)
                    .stroke(Theme.paper, style: StrokeStyle(lineWidth: width * 1.1, lineCap: .round, dash: [0, 2.3 * width]))
            }
        }
    }
}

struct RunWalkBar: View {
    let segments: [MoveSegment]
    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.meters })
        GeometryReader { geo in
            let gaps = CGFloat(max(0, segments.count - 1)) * 3
            HStack(spacing: 3) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    let w = max(3, (geo.size.width - gaps) * s.meters / total)
                    if s.kind == .run {
                        Capsule().fill(Theme.paper).frame(width: w)
                    } else {
                        DottedLine().frame(width: w)
                    }
                }
            }
        }
        .frame(height: 6)
    }
}

private struct DottedLine: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 1.5, y: 3)); p.addLine(to: CGPoint(x: geo.size.width, y: 3))
            }
            .stroke(Theme.dim, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, dash: [0, 6]))
        }
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.paper))
            .padding(.horizontal, 16)
    }
}
