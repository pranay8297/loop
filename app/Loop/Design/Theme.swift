import SwiftUI

/// Two tones plus one accent. The accent marks state only.
enum Theme {
    static let ink = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)
    static let paper = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF1 / 255)
    static let dim = paper.opacity(0.55)
    static let surface1 = paper.opacity(0.06)
    static let surface2 = paper.opacity(0.11)
    static let hairline = paper.opacity(0.10)
    static let accent = Color(red: 0x5A / 255, green: 0x78 / 255, blue: 0xFF / 255)

    static func number(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold).monospacedDigit()
    }
    static let label = Font.system(size: 10, weight: .semibold)
    static func title(_ size: CGFloat = 30) -> Font { .system(size: size, weight: .semibold) }
}

struct MonoLabel: View {
    let text: String
    var color: Color = Theme.dim
    init(_ text: String, color: Color = Theme.dim) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(Theme.label).tracking(1.2).foregroundStyle(color)
    }
}

struct TitleText: View {
    let text: String
    var size: CGFloat = 30
    var body: some View {
        Text(text).font(Theme.title(size)).tracking(-size * 0.035).foregroundStyle(Theme.paper)
    }
}

struct StatCell: View {
    let value: String
    let unit: String
    var size: CGFloat = 25
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Theme.number(size)).foregroundStyle(Theme.paper)
            Text(unit).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(Theme.paper))
            .foregroundStyle(Theme.ink)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(Theme.surface2))
            .foregroundStyle(Theme.paper)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct ChipStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(selected ? Theme.ink : Theme.dim)
            .background(Capsule().fill(selected ? Theme.paper : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

enum Format {
    static func duration(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static func km(_ meters: Double) -> String { String(format: "%.2f", meters / 1000) }
    static func pace(_ secPerKm: Double?) -> String {
        guard let p = secPerKm, p.isFinite, p > 0, p < 3600 else { return "-:--" }
        let t = Int(p.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
    static func hoursMinutes(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) m" : "\(m) m"
    }
    static func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: d)
    }
    static func clock(_ d: Date, tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm"; f.timeZone = tz; return f.string(from: d)
    }
    static func clockAMPM(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }
}
