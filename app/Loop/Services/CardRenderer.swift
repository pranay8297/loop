import SwiftUI
import SwiftData

/// Renders a share card to a 1080x1920 image. Awaits the map snapshot first; renders without it on failure.
@MainActor
enum CardRenderer {
    static let scale: CGFloat = 3

    /// Snapshot sized and boxed for the card styles that show a map.
    static func snapshot(for data: CardData, style: CardStyle, timeout: Double = 10) async -> MapSnap? {
        let box = style == .photo ? PhotoCard.routeBox : CityCard.routeBox
        return await MapSnapshot.make(id: data.id, route: data.route, size: CardText.cardSize,
                                      routeBox: box, scale: scale, timeout: timeout)
    }

    /// Whether a style needs a map snapshot. The landmark City card draws without a map.
    static func needsSnapshot(_ style: CardStyle, data: CardData, photo: UIImage? = nil) -> Bool {
        (style == .city && data.packCity == nil) || (style == .photo && photo == nil)
    }

    static func render(_ style: CardStyle, data: CardData, hide: Bool, snap: MapSnap?, photo: UIImage? = nil,
                       cityTone: CityTone = .dark) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCard(style: style, data: data, hide: hide, snap: snap, photo: photo, cityTone: cityTone))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(CardText.cardSize)
        renderer.isOpaque = true
        return renderer.uiImage
    }

    static func render(_ style: CardStyle, workout: Workout, history: [DayEntry], hide: Bool,
                       photo: UIImage? = nil, cityTone: CityTone = .dark, timeout: Double = 10) async -> UIImage? {
        let data = CardData(workout: workout, history: history)
        let snap = needsSnapshot(style, data: data, photo: photo) ? await snapshot(for: data, style: style, timeout: timeout) : nil
        return render(style, data: data, hide: hide, snap: snap, photo: photo, cityTone: cityTone)
    }

    /// Every workout as a Month-card day entry.
    static func history(in ctx: ModelContext) -> [DayEntry] {
        ((try? ctx.fetch(FetchDescriptor<Workout>())) ?? []).map { DayEntry(date: $0.startDate, kind: $0.kind, meters: $0.distanceMeters) }
    }
}
