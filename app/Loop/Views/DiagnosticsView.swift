import SwiftUI

/// Apple's daily MetricKit numbers and Loop's own GPS log. Everything here stays on the phone.
struct DiagnosticsView: View {
    @State private var days: [MetricsDay] = []
    @State private var events: [PowerLog.Event] = []
    @State private var gpsToday: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TitleText(text: "Battery", size: 22)
                Text("From Apple's daily report and Loop's own log. Nothing leaves your phone.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim).padding(.top, 4)

                MonoLabel("Daily report").padding(.top, 22)
                if days.isEmpty {
                    Text("Apple sends these once a day. The first report arrives within 24 hours.")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim).padding(.top, 8)
                        .accessibilityIdentifier("metricsEmpty")
                } else {
                    ForEach(days, id: \.day) { d in dayRow(d) }
                }

                MonoLabel("GPS today").padding(.top, 26)
                Text(Self.duration(gpsToday)).font(Theme.number(25)).foregroundStyle(Theme.paper).padding(.top, 6)
                    .accessibilityIdentifier("gpsToday")
                Text("Time GPS was on, from Loop's log.").font(.system(size: 10.5)).foregroundStyle(Theme.dim)

                MonoLabel("Last 2 days").padding(.top, 22)
                if events.isEmpty {
                    Text("Nothing logged yet.").font(.system(size: 13)).foregroundStyle(Theme.dim).padding(.top, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Self.time(e.time)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
                                    .frame(width: 92, alignment: .leading)
                                Text(Self.label(e.kind)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.paper)
                                Spacer()
                                Text(e.reason).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                            }
                            .padding(.vertical, 8)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .accessibilityIdentifier("diagnosticsScreen")
        .task { load() }
    }

    private func load() {
        days = MetricsStore.shared.days()
        let all = PowerLog.shared?.events() ?? []
        let now = Date()
        gpsToday = PowerLog.gpsSeconds(all, on: now, now: now)
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now)) ?? now
        events = all.filter { $0.time >= cutoff }.sorted { $0.time > $1.time }
    }

    private func dayRow(_ d: MetricsDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Format.dayLabel(d.day)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.paper)
            if d.hasMetrics {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        StatCell(value: Self.duration(d.background), unit: "background", size: 17)
                        StatCell(value: Self.duration(d.backgroundLocation), unit: "background location", size: 17)
                    }
                    GridRow {
                        StatCell(value: Self.duration(d.cpu), unit: "CPU", size: 17)
                        StatCell(value: Self.duration(d.foreground), unit: "foreground", size: 17)
                    }
                }
            }
            Text("\(d.crashes) crashes · \(d.hangs) hangs · \(d.cpuExceptions) CPU warnings")
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded(.down))
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        if m > 0 { return "\(m)m" }
        return "\(Int(s.rounded()))s"
    }

    static func label(_ k: PowerLog.Kind) -> String {
        switch k {
        case .gpsOn: "GPS on"
        case .gpsOff: "GPS off"
        case .launch: "Opened"
        case .foreground: "Foreground"
        case .background: "Background"
        }
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "EEE HH:mm"
        return f.string(from: d)
    }
}
