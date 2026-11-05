import Foundation
import MetricKit

/// One day of Apple's MetricKit numbers for Loop, parsed from the payload JSON.
struct MetricsDay: Equatable, Sendable {
    var day: Date
    var foreground: Double = 0
    var background: Double = 0
    var backgroundLocation: Double = 0
    var cpu: Double = 0
    var locationNavigation: Double = 0
    var locationBest: Double = 0
    var networkUp: Double = 0
    var networkDown: Double = 0
    var crashes = 0
    var hangs = 0
    var cpuExceptions = 0
    var hasMetrics = false
}

/// Keeps MetricKit's daily reports on the phone (Application Support/metrics, newest 30 of
/// each kind) and parses them for the diagnostics screen. Nothing is sent anywhere.
final class MetricsStore: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsStore()
    static let keep = 30

    let dir: URL
    private var started = false

    init(dir: URL? = nil) {
        self.dir = dir ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("metrics", isDirectory: true)
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        let m = MXMetricManager.shared
        m.add(self)
        ingest(metrics: m.pastPayloads.map { $0.jsonRepresentation() })
        ingest(diagnostics: m.pastDiagnosticPayloads.map { $0.jsonRepresentation() })
    }

    func didReceive(_ payloads: [MXMetricPayload]) { ingest(metrics: payloads.map { $0.jsonRepresentation() }) }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { ingest(diagnostics: payloads.map { $0.jsonRepresentation() }) }

    // MARK: storage

    func ingest(metrics: [Data]) { metrics.forEach { write($0, prefix: "metric") } }
    func ingest(diagnostics: [Data]) { diagnostics.forEach { write($0, prefix: "diag") } }

    /// Files are named by the payload's time range plus a content hash, so the same payload
    /// (delivered again as a past payload) is stored once.
    private func write(_ json: Data, prefix: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let begin = (obj["timeStampBegin"] as? String).flatMap(Self.parseDate)
        let stamp = Int((begin ?? Date()).timeIntervalSince1970)
        let name = "\(prefix)-\(stamp)-\(Self.fnv(json)).json"
        let url = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: url.path) { try? json.write(to: url, options: .atomic) }
        prune(prefix: prefix)
    }

    private func files(prefix: String) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(prefix + "-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func prune(prefix: String) {
        for u in files(prefix: prefix).dropFirst(Self.keep) { try? FileManager.default.removeItem(at: u) }
    }

    /// Parsed days, newest first.
    func days() -> [MetricsDay] {
        let m = files(prefix: "metric").compactMap { try? Data(contentsOf: $0) }
        let d = files(prefix: "diag").compactMap { try? Data(contentsOf: $0) }
        return Self.summarize(metrics: m, diagnostics: d)
    }

    // MARK: parsing

    static func summarize(metrics: [Data], diagnostics: [Data], calendar: Calendar = .current) -> [MetricsDay] {
        var byDay: [Date: MetricsDay] = [:]
        func day(_ obj: [String: Any]) -> Date? {
            guard let s = (obj["timeStampBegin"] as? String) ?? (obj["timeStampEnd"] as? String), let d = parseDate(s) else { return nil }
            return calendar.startOfDay(for: d)
        }
        for data in metrics {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let k = day(obj) else { continue }
            var v = byDay[k] ?? MetricsDay(day: k)
            let p = parseMetric(obj)
            v.foreground += p.foreground; v.background += p.background; v.backgroundLocation += p.backgroundLocation
            v.cpu += p.cpu; v.locationNavigation += p.locationNavigation; v.locationBest += p.locationBest
            v.networkUp += p.networkUp; v.networkDown += p.networkDown
            v.hasMetrics = true
            byDay[k] = v
        }
        for data in diagnostics {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let k = day(obj) else { continue }
            var v = byDay[k] ?? MetricsDay(day: k)
            v.crashes += (obj["crashDiagnostics"] as? [Any])?.count ?? 0
            v.hangs += (obj["hangDiagnostics"] as? [Any])?.count ?? 0
            v.cpuExceptions += (obj["cpuExceptionDiagnostics"] as? [Any])?.count ?? 0
            byDay[k] = v
        }
        return byDay.values.sorted { $0.day > $1.day }
    }

    /// Reads the fields Loop shows from one `MXMetricPayload.jsonRepresentation()`.
    static func parseMetric(_ obj: [String: Any]) -> MetricsDay {
        var v = MetricsDay(day: .distantPast)
        let run = obj["applicationTimeMetrics"] as? [String: Any] ?? [:]
        v.foreground = seconds(run["cumulativeForegroundTime"])
        v.background = seconds(run["cumulativeBackgroundTime"])
        v.backgroundLocation = seconds(run["cumulativeBackgroundLocationTime"])
        let cpu = obj["cpuMetrics"] as? [String: Any] ?? [:]
        v.cpu = seconds(cpu["cumulativeCPUTime"])
        let loc = obj["locationActivityMetrics"] as? [String: Any] ?? [:]
        v.locationNavigation = seconds(loc["cumulativeBestAccuracyForNavigationTime"])
        v.locationBest = seconds(loc["cumulativeBestAccuracyTime"])
        let net = obj["networkTransferMetrics"] as? [String: Any] ?? [:]
        v.networkUp = bytes(net["cumulativeWifiUpload"]) + bytes(net["cumulativeCellularUpload"])
        v.networkDown = bytes(net["cumulativeWifiDownload"]) + bytes(net["cumulativeCellularDownload"])
        v.hasMetrics = true
        return v
    }

    /// "700 sec", "1.5 min", "2 hours" or a bare number of seconds.
    static func seconds(_ any: Any?) -> Double {
        let (n, unit) = measure(any)
        switch unit {
        case "ms": return n / 1000
        case "min", "mins", "minute", "minutes": return n * 60
        case "h", "hr", "hrs", "hour", "hours": return n * 3600
        default: return n
        }
    }

    /// "80000 kB", "2 MB" or a bare number of bytes.
    static func bytes(_ any: Any?) -> Double {
        let (n, unit) = measure(any)
        switch unit.lowercased() {
        case "kb": return n * 1000
        case "mb": return n * 1_000_000
        case "gb": return n * 1_000_000_000
        default: return n
        }
    }

    private static func measure(_ any: Any?) -> (Double, String) {
        if let n = any as? NSNumber { return (n.doubleValue, "") }
        guard let s = any as? String else { return (0, "") }
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        let n = Double(parts.first?.replacingOccurrences(of: ",", with: "") ?? "") ?? 0
        return (n, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }

    static func parseDate(_ s: String) -> Date? {
        for f in dateFormatters { if let d = f.date(from: s) { return d } }
        return ISO8601DateFormatter().date(from: s)
    }

    private static let dateFormatters: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"].map {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = $0
        f.timeZone = TimeZone(identifier: "UTC"); return f
    }

    private static func fnv(_ d: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in d { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
