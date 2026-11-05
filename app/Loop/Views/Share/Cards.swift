import SwiftUI
import CoreLocation

enum CardStyle: String, CaseIterable, Identifiable {
    case city, line, photo, bib, receipt, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .city: "City"
        case .line: "Line"
        case .photo: "Photo"
        case .bib: "Bib"
        case .receipt: "Receipt"
        case .month: "Month"
        }
    }
    var usesRoute: Bool { self == .city || self == .line || self == .photo }
}

/// One day in the Month card history.
struct DayEntry: Sendable {
    var date: Date
    var kind: ActivityKind
    var meters: Double
}

/// Card text and numbers, built once from a workout.
struct CardText {
    static let cardSize = CGSize(width: 360, height: 640)

    /// place → city → "Your run".
    static func place(placeName: String?, cityName: String?, kind: ActivityKind) -> String {
        if let p = placeName?.trimmed, !p.isEmpty { return p }
        if let c = cityName?.trimmed, !c.isEmpty { return c }
        return "Your \(kind.noun)"
    }
    /// City shown under the place only when known and different from it.
    static func city(placeName: String?, cityName: String?) -> String? {
        guard let c = cityName?.trimmed, !c.isEmpty else { return nil }
        let p = (placeName?.trimmed ?? "")
        if p.isEmpty || p.caseInsensitiveCompare(c) == .orderedSame { return nil }
        return c
    }
    static func coordinate(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.2f° %@ %.2f° %@", abs(c.latitude), c.latitude >= 0 ? "N" : "S", abs(c.longitude), c.longitude >= 0 ? "E" : "W")
    }
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yy · HH:mm"; return f.string(from: d)
    }
}

struct CardData {
    var id: UUID
    var kind: ActivityKind
    var date: Date
    var place: String
    var city: String?
    var hasPlace: Bool
    var coordinate: CLLocationCoordinate2D?
    var name: String
    var km: String
    var distanceKm: Double
    var time: String
    var paceValue: String   // "6:23" or "24.1"
    var paceUnit: String    // "/km" or "km/h"
    var ranPercent: Int?
    var runKm: Double
    var walkKm: Double
    var steps: Int?
    var splits: [Split]
    var route: [RoutePoint]
    var segments: [MoveSegment]
    var history: [DayEntry]

    init(workout w: Workout, history: [DayEntry] = []) {
        id = w.id
        kind = w.kind
        date = w.startDate
        place = CardText.place(placeName: w.placeName, cityName: w.cityName, kind: w.kind)
        city = CardText.city(placeName: w.placeName, cityName: w.cityName)
        hasPlace = (w.placeName?.trimmed.isEmpty == false) || (w.cityName?.trimmed.isEmpty == false)
        route = w.route
        segments = w.segments
        coordinate = RouteGeometry.midpoint(route).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        name = w.name.isEmpty ? place : w.name
        km = Format.km(w.distanceMeters)
        distanceKm = w.distanceMeters / 1000
        time = Format.duration(w.movingSeconds)
        if w.kind == .ride {
            let h = w.movingSeconds / 3600
            paceValue = h > 0 ? String(format: "%.1f", w.distanceMeters / 1000 / h) : "--"
            paceUnit = "km/h"
        } else {
            paceValue = Format.pace(w.avgPace)
            paceUnit = "/km"
        }
        ranPercent = (w.kind == .run && w.walkMeters > 0) ? w.runFraction.map { Int(($0 * 100).rounded()) } : nil
        runKm = w.runMeters / 1000
        walkKm = w.walkMeters / 1000
        steps = w.steps
        splits = SplitsCalculator.splits(route)
        self.history = history
    }

    var shortName: String { hasPlace ? "\(place) \(kind.noun)" : place }
    var paceText: String { "\(paceValue) \(paceUnit)" }
    var paceLabel: String { kind == .ride ? "Speed" : "Pace" }

    /// Mono row: time · pace · ran%.
    var monoLine: String {
        var parts = [time, paceText]
        if let r = ranPercent { parts.append("ran \(r)%") }
        return parts.joined(separator: " · ")
    }

    func pieces(hide: Bool) -> [RoutePiece] { CardRoute.pieces(route, segments: segments, hide: hide) }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

// MARK: Card host

struct ShareCard: View {
    let style: CardStyle
    let data: CardData
    var hide = true
    var snap: MapSnap?
    var photo: UIImage?

    var body: some View {
        Group {
            switch style {
            case .city: CityCard(data: data, hide: hide, snap: snap)
            case .line: LineCard(data: data, hide: hide)
            case .photo: PhotoCard(data: data, hide: hide, snap: snap, photo: photo)
            case .bib: BibCard(data: data)
            case .receipt: ReceiptCard(data: data)
            case .month: MonthCard(data: data)
            }
        }
        .frame(width: CardText.cardSize.width, height: CardText.cardSize.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

private let W: CGFloat = 360
private let cq: CGFloat = W / 100   // 1% of card width, matches the design's cqw

private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight == .regular ? .medium : weight).monospacedDigit()
}
private func bigNumber(_ size: CGFloat) -> Font {
    .system(size: size, weight: .semibold).monospacedDigit()
}

private struct CardTop: View {
    var color: Color = Theme.paper
    let date: String
    var body: some View {
        HStack {
            LoopWordmark(color: color, size: 4.4 * cq)
            Spacer()
            Text(date).font(mono(2.6 * cq)).tracking(0.26 * cq).foregroundStyle(color.opacity(0.55))
        }
        .padding(.horizontal, 6 * cq).padding(.top, 6 * cq)
    }
}

private struct BigKm: View {
    let km: String
    var unit = "km"
    var color: Color = Theme.paper
    var size: CGFloat = 30 * cq
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2 * cq) {
            Text(km).font(bigNumber(size)).tracking(-size * 0.04).minimumScaleFactor(0.5)
            Text(unit).font(.system(size: 6.4 * cq, weight: .medium)).opacity(0.7)
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

private struct LabelledStats: View {
    let items: [(String, String)]
    var color: Color = Theme.paper
    var body: some View {
        HStack(alignment: .top, spacing: 7 * cq) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 1.1 * cq) {
                    Text(items[i].0.uppercased()).font(mono(2.2 * cq)).tracking(0.26 * cq).opacity(0.5)
                    Text(items[i].1).font(mono(3.3 * cq))
                }
            }
        }
        .foregroundStyle(color)
    }
}

private func statItems(_ d: CardData) -> [(String, String)] {
    var a = [("Time", d.time), (d.paceLabel, d.paceText)]
    if let r = d.ranPercent { a.append(("Ran", "\(r)%")) }
    return a
}

// MARK: 1. City

struct CityCard: View {
    let data: CardData
    var hide: Bool
    var snap: MapSnap?

    /// Where the route sits on the card; the snapshot is requested with the same box.
    static let routeBox = CGRect(x: 30, y: 230, width: 300, height: 210)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.ink
            if let snap {
                Image(uiImage: snap.image).resizable().frame(width: W, height: 640).opacity(0.6)
            }
            BottomScrim()
            route
            VStack(alignment: .leading, spacing: 0) {
                CardTop(date: CardText.stamp(data.date))
                Text(data.place.uppercased())
                    .font(.system(size: 14 * cq, weight: .bold))
                    .tracking(-0.6 * cq)
                    .lineSpacing(-2 * cq)
                    .lineLimit(2)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(Theme.paper)
                    .padding(.top, 8 * cq)
                    .padding(.horizontal, 6 * cq)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subline).font(mono(2.8 * cq)).tracking(0.3 * cq).foregroundStyle(Theme.paper.opacity(0.6))
                    .padding(.top, 2.6 * cq).padding(.horizontal, 6 * cq)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    BigKm(km: data.km, size: 26 * cq)
                    Text(data.monoLine.uppercased()).font(mono(3.3 * cq)).tracking(0.2 * cq)
                        .foregroundStyle(Theme.paper.opacity(0.85)).padding(.top, 4 * cq)
                }
                .padding(.horizontal, 6 * cq).padding(.bottom, 12 * cq)
            }
        }
    }

    private var subline: String {
        var parts: [String] = []
        if let c = data.city { parts.append(c.uppercased()) }
        if let c = data.coordinate { parts.append(CardText.coordinate(c)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var route: some View {
        let pieces = data.pieces(hide: hide)
        let drawn = snap.map { s in RouteInk.projected(pieces, with: { c in
            // snapshot points are in snapshot size, which equals the card size
            s.project(c)
        }) } ?? RouteInk.fitted(pieces, in: Self.routeBox)
        RouteInk(pieces: drawn, color: Theme.paper, width: 1.3 * cq, showFinish: !drawn.isEmpty)
    }
}

// MARK: 2. Line

struct LineCard: View {
    let data: CardData
    var hide: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.ink
            RouteInk(pieces: RouteInk.fitted(data.pieces(hide: hide), in: CGRect(x: 9 * cq, y: 17 * cq, width: 82 * cq, height: 94 * cq), padding: 4),
                     color: Theme.paper, width: 1.4 * cq)
            CardTop(date: CardText.stamp(data.date))
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Text(data.name).font(.system(size: 4.6 * cq, weight: .medium)).tracking(-0.07 * cq)
                    .foregroundStyle(Theme.paper.opacity(0.7)).lineLimit(2)
                BigKm(km: data.km).padding(.top, 3 * cq)
                LabelledStats(items: statItems(data)).padding(.top, 4.6 * cq)
            }
            .padding(.horizontal, 6 * cq).padding(.bottom, 7 * cq)
        }
    }
}

// MARK: 3. Photo

struct PhotoCard: View {
    let data: CardData
    var hide: Bool
    var snap: MapSnap?
    var photo: UIImage?
    static let routeBox = CGRect(x: 13 * cq, y: 12 * cq, width: 74 * cq, height: 70 * cq)

    /// On the map background the route follows the map; on a photo it is fitted to the box.
    private var drawn: [DrawnPiece] {
        let pieces = data.pieces(hide: hide)
        if photo == nil, let snap { return RouteInk.projected(pieces, with: snap.project) }
        return RouteInk.fitted(pieces, in: Self.routeBox, padding: 4)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.ink
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill().frame(width: W, height: 640).clipped()
                    .saturation(0).contrast(1.06)
            } else if let snap {
                Image(uiImage: snap.image).resizable().frame(width: W, height: 640).opacity(0.5)
            }
            BottomScrim()
            RouteInk(pieces: drawn, color: Theme.paper, width: 1.6 * cq, shadow: true)
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                BigKm(km: data.km)
                Text(data.monoLine.uppercased()).font(mono(3.3 * cq)).padding(.top, 3.6 * cq)
                HStack(spacing: 3 * cq) {
                    Text(data.name).font(.system(size: 3.8 * cq, weight: .medium)).opacity(0.85).lineLimit(1)
                    Spacer()
                    LoopWordmark(size: 4.4 * cq)
                }
                .padding(.top, 4.4 * cq)
            }
            .foregroundStyle(Theme.paper)
            .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
            .padding(.horizontal, 6 * cq).padding(.bottom, 7 * cq)
        }
    }
}

// MARK: 4. Bib

struct BibCard: View {
    let data: CardData
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd MMM"; return f }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.paper
            Text("No race.\nStill got a bib.")
                .font(.system(size: 8.6 * cq, weight: .semibold)).tracking(-0.34 * cq).lineSpacing(-1 * cq)
                .foregroundStyle(Theme.ink)
                .padding(.top, 13 * cq).padding(.horizontal, 8 * cq)
            bib
                .rotationEffect(.degrees(-3))
                .padding(.horizontal, 10 * cq)
                .padding(.top, 44 * cq)
            HStack {
                LoopWordmark(color: Theme.ink, size: 4.4 * cq)
                Spacer()
                Text((data.hasPlace ? data.place : "").uppercased()).font(mono(2.6 * cq)).tracking(0.26 * cq)
                    .foregroundStyle(Theme.ink.opacity(0.55)).lineLimit(1)
            }
            .padding(.horizontal, 8 * cq)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 7 * cq)
        }
    }

    private var bib: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LOOP RUN CLUB"); Spacer(); Text(Self.day.string(from: data.date).uppercased())
            }
            .font(mono(2.4 * cq)).tracking(0.38 * cq).opacity(0.6)
            .padding(.horizontal, 2 * cq).padding(.top, 3.4 * cq)
            Text(data.km).font(bigNumber(34 * cq)).tracking(-1.5 * cq).lineLimit(1).minimumScaleFactor(0.5)
                .padding(.top, 5 * cq)
            Text(data.kind == .run ? "KILOMETRES" : "KILOMETRES").font(mono(2.5 * cq)).tracking(0.85 * cq).opacity(0.6).padding(.top, 2.8 * cq)
            Text(data.shortName).font(.system(size: 5.6 * cq, weight: .semibold)).tracking(-0.1 * cq)
                .lineLimit(1).minimumScaleFactor(0.6).padding(.top, 3.6 * cq)
            Line().stroke(Theme.paper.opacity(0.25), style: StrokeStyle(lineWidth: 0.4 * cq, dash: [1.2 * cq, 1.2 * cq]))
                .frame(height: 1).padding(.top, 4.4 * cq)
            HStack(spacing: 0) {
                bibStat("TIME", data.time)
                bibStat(data.kind == .ride ? "KM/H" : "PACE", data.paceValue)
                if let r = data.ranPercent { bibStat("RAN", "\(r)%") }
            }
            .padding(.top, 3.6 * cq)
        }
        .foregroundStyle(Theme.paper)
        .padding(.horizontal, 6 * cq).padding(.bottom, 6 * cq)
        .background(RoundedRectangle(cornerRadius: 2.4 * cq).fill(Theme.ink))
        .overlay {
            GeometryReader { g in
                ForEach(0..<4, id: \.self) { i in
                    pin.position(x: i % 2 == 0 ? 3.4 * cq : g.size.width - 3.4 * cq,
                                 y: i < 2 ? 3.4 * cq : g.size.height - 3.4 * cq)
                }
            }
        }
    }

    private var pin: some View {
        Circle().fill(Theme.paper.opacity(0.78)).frame(width: 2.8 * cq, height: 2.8 * cq)
            .overlay(Circle().strokeBorder(Theme.paper.opacity(0.5), lineWidth: 0.5 * cq))
    }

    private func bibStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1.3 * cq) {
            Text(label).font(mono(2.1 * cq)).tracking(0.3 * cq).opacity(0.5)
            Text(value).font(bigNumber(7 * cq))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Line: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: 0, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p }
}

// MARK: 5. Receipt

/// A rectangle with a zigzag torn bottom edge.
struct TornPaper: Shape {
    var tooth: CGFloat = 11.5
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: r.maxX, y: 0))
        let n = max(2, Int((r.width / tooth).rounded()))
        let step = r.width / CGFloat(n)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - step / 2))
        for i in stride(from: n, to: 0, by: -1) {
            let x = CGFloat(i) * step
            p.addLine(to: CGPoint(x: x - step / 2, y: r.maxY))
            p.addLine(to: CGPoint(x: x - step, y: r.maxY - step / 2))
        }
        p.closeSubpath()
        return p
    }
}

/// Deterministic bars from the workout id.
struct Barcode: View {
    let seed: UUID
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRNG(seed)
            var x: CGFloat = 0
            while x < size.width {
                let w = (0.6 + rng.next() * 2.2) * size.width / 100
                if rng.next() > 0.35 {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: min(w, size.width - x), height: size.height)), with: .color(Theme.ink))
                }
                x += w + 0.5 * size.width / 100
            }
        }
    }
}

struct SeededRNG {
    private var state: UInt64
    init(_ id: UUID) {
        let b = withUnsafeBytes(of: id.uuid) { Array($0) }
        state = b.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) } ^ 0x9E37_79B9_7F4A_7C15
        if state == 0 { state = 1 }
    }
    /// 0..<1
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

struct ReceiptCard: View {
    let data: CardData
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE dd MMM yyyy · HH:mm"; return f }()

    var body: some View {
        let rows = splitRows
        let font = mono(rows.count > 9 ? 2.7 * cq : 3.1 * cq)
        ZStack(alignment: .topLeading) {
            Theme.ink
            VStack(spacing: 0) {
                Text("Loop Run Club").font(.system(size: 6 * cq, weight: .semibold)).tracking(-0.24 * cq)
                VStack(spacing: 0) {
                    Text([data.hasPlace ? data.place : nil, data.city].compactMap { $0 }.joined(separator: ", ").uppercased())
                    Text(Self.day.string(from: data.date).uppercased())
                }
                .multilineTextAlignment(.center).opacity(0.6).padding(.top, 1.8 * cq)
                rule
                ForEach(rows.indices, id: \.self) { i in row(rows[i].0, rows[i].1, best: rows[i].2) }
                rule
                row(data.kind == .run ? "RUNNING" : "MOVING", String(format: "%.2f KM", data.kind == .run && data.runKm > 0 ? data.runKm : data.distanceKm))
                if data.walkKm > 0 { row("WALKING", String(format: "%.2f KM", data.walkKm)) }
                row("TIME", data.time)
                row(data.kind == .ride ? "AVG SPEED" : "AVG PACE", data.paceValue + data.paceUnit.uppercased().replacingOccurrences(of: " ", with: ""))
                if let s = data.steps { row("STEPS", s.formatted()) }
                rule
                Barcode(seed: data.id).frame(height: 7 * cq).padding(.horizontal, 5 * cq).padding(.top, 1 * cq)
                Text("THANK YOU FOR RUNNING\nNO SUBSCRIPTION NEEDED").multilineTextAlignment(.center).opacity(0.6).padding(.top, 2.4 * cq)
            }
            .font(font).lineSpacing(0.5 * cq)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 6 * cq).padding(.top, 7 * cq).padding(.bottom, 9 * cq)
            .background(TornPaper(tooth: 3.2 * cq).fill(Theme.paper))
            .padding(.horizontal, 11 * cq).padding(.top, 9 * cq)
            HStack {
                LoopWordmark(size: 4.4 * cq)
                Spacer()
                Text(CardText.stamp(data.date).components(separatedBy: " ").first ?? "").font(mono(2.6 * cq)).foregroundStyle(Theme.paper.opacity(0.55))
            }
            .padding(.horizontal, 8 * cq)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 7 * cq)
        }
    }

    private var splitRows: [(String, String, Bool)] {
        let s = data.splits
        let fastest = SplitsCalculator.fastestFullIndex(s)
        var rows: [(String, String, Bool)] = []
        let limit = 12
        for sp in s.prefix(limit) {
            let label = sp.isFull ? "KM \(sp.index)" : String(format: "%.2f KM", sp.meters / 1000)
            rows.append((label, sp.isFull ? Format.pace(sp.pace) : Format.duration(sp.seconds), sp.index == fastest && s.filter(\.isFull).count > 1))
        }
        if s.count > limit { rows.append(("+\(s.count - limit) MORE KM", "", false)) }
        return rows
    }

    private var rule: some View {
        Line().stroke(Theme.ink.opacity(0.4), style: StrokeStyle(lineWidth: 0.35 * cq, dash: [1 * cq, 0.8 * cq]))
            .frame(height: 1).padding(.vertical, 2.8 * cq)
    }

    private func row(_ a: String, _ b: String, best: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1.4 * cq) {
            Text(a)
            Line().stroke(Theme.ink.opacity(0.35), style: StrokeStyle(lineWidth: 0.3 * cq, dash: [0.3 * cq, 0.9 * cq]))
                .frame(height: 1)
            if best {
                (Text("● ").foregroundStyle(Theme.accent) + Text(b).foregroundStyle(Theme.accent)).fontWeight(.semibold)
            } else {
                Text(b)
            }
        }
        .lineLimit(1)
    }
}

// MARK: 6. Month

struct MonthCard: View {
    let data: CardData
    var today = Date()

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.timeZone = .current; return c }

    var body: some View {
        let days = gridDays
        let byDay = Dictionary(grouping: data.history, by: { cal.startOfDay(for: $0.date) })
        let firstDay = days.first ?? today
        let window = data.history.filter { $0.date >= firstDay && $0.date <= today }
        ZStack(alignment: .topLeading) {
            Theme.ink
            CardTop(date: range(days))
            Text(title).font(.system(size: 11 * cq, weight: .semibold)).tracking(-0.5 * cq)
                .foregroundStyle(Theme.paper).padding(.top, 17 * cq).padding(.horizontal, 6 * cq)
            HStack(spacing: 4.4 * cq) {
                legend(Circle().fill(Theme.paper), "Run")
                legend(Circle().strokeBorder(Theme.paper, lineWidth: 0.5 * cq), "Swim")
                legend(RoundedRectangle(cornerRadius: 0.3 * cq).fill(Theme.paper), "Gym")
            }
            .font(.system(size: 3 * cq)).foregroundStyle(Theme.paper.opacity(0.7))
            .padding(.top, 31 * cq).padding(.horizontal, 6 * cq)
            grid(days, byDay).padding(.top, 42 * cq).padding(.horizontal, 6 * cq)
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                BigKm(km: "\(window.count)", unit: window.count == 1 ? "workout" : "workouts")
                Text(totals(window)).font(mono(2.9 * cq)).foregroundStyle(Theme.paper.opacity(0.65)).padding(.top, 4 * cq)
            }
            .padding(.horizontal, 6 * cq).padding(.bottom, 7 * cq)
        }
    }

    private var title: String {
        guard let first = data.history.map(\.date).min() else { return "This month" }
        let n = (cal.dateComponents([.day], from: cal.startOfDay(for: first), to: cal.startOfDay(for: today)).day ?? 0) + 1
        return n < 7 ? "This month" : "\(n) days in"
    }

    /// 28 days, Monday to Sunday, ending with this week.
    private var gridDays: [Date] {
        let start = cal.startOfDay(for: today)
        let weekday = (cal.component(.weekday, from: start) + 5) % 7 // Monday = 0
        let monday = cal.date(byAdding: .day, value: -weekday - 21, to: start)!
        return (0..<28).map { cal.date(byAdding: .day, value: $0, to: monday)! }
    }

    private func range(_ days: [Date]) -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM"
        return "\(f.string(from: days.first ?? today)) TO \(f.string(from: today))"
    }

    private func legend<S: View>(_ shape: S, _ text: String) -> some View {
        HStack(spacing: 1.4 * cq) { shape.frame(width: 2.4 * cq, height: 2.4 * cq); Text(text) }
    }

    private func grid(_ days: [Date], _ byDay: [Date: [DayEntry]]) -> some View {
        let cell = (W - 12 * cq) / 7
        let todayStart = cal.startOfDay(for: today)
        return VStack(spacing: 1.8 * cq) {
            HStack(spacing: 0) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(mono(5.4 * cq * 0.88 * 0.5))
                        .foregroundStyle(Theme.paper.opacity(0.45)).frame(width: cell)
                }
            }
            ForEach(0..<4, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { c in
                        let d = days[r * 7 + c]
                        dayCell(entries: byDay[d] ?? [], future: d > todayStart, isToday: d == todayStart, cell: cell)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(entries: [DayEntry], future: Bool, isToday: Bool, cell: CGFloat) -> some View {
        ZStack {
            if isToday { Circle().strokeBorder(Theme.accent, lineWidth: 0.7 * cq) }
            if let e = pick(entries) {
                switch e.kind {
                case .swim:
                    let s = cell * min(0.72, 0.36 + e.meters / 1200 * 0.36)
                    Circle().strokeBorder(Theme.paper, lineWidth: 2.2 * cq * 0.5).frame(width: s, height: s)
                case .gym:
                    RoundedRectangle(cornerRadius: 1.4 * cq * 0.5).fill(Theme.paper).frame(width: cell * 0.4, height: cell * 0.4)
                default:
                    let km = entries.filter { $0.kind.isGPS }.reduce(0) { $0 + $1.meters } / 1000
                    let s = cell * min(0.8, 0.24 + km * 0.08)
                    Circle().fill(Theme.paper).frame(width: s, height: s)
                }
            } else if future {
                Circle().strokeBorder(Theme.paper.opacity(0.3), lineWidth: 0.5 * cq).frame(width: 2.8 * cq, height: 2.8 * cq)
            } else {
                Circle().fill(Theme.paper.opacity(0.18)).frame(width: 2.8 * cq, height: 2.8 * cq)
            }
        }
    }

    private func pick(_ e: [DayEntry]) -> DayEntry? {
        e.first(where: { $0.kind.isGPS }) ?? e.first(where: { $0.kind == .swim }) ?? e.first
    }

    private func totals(_ w: [DayEntry]) -> String {
        let km = w.filter { $0.kind == .run }.reduce(0) { $0 + $1.meters } / 1000
        let swims = w.filter { $0.kind == .swim }.count
        let gym = w.filter { $0.kind == .gym }.count
        return String(format: "%.1f KM RUN · %d SWIM%@ · %d GYM", km, swims, swims == 1 ? "" : "S", gym)
    }
}

/// Ink scrim over the lower half of map and photo cards so labels never fight the stats.
/// Eases off in the last ~28 pt so the Apple Maps attribution stays legible.
struct BottomScrim: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Theme.ink.opacity(0), location: 0.5),
            .init(color: Theme.ink.opacity(0.9), location: 0.93),
            .init(color: Theme.ink.opacity(0.35), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }
}
