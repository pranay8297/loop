import Foundation

/// An on-device log of what uses power: when GPS went on and off and why, launches, and
/// foreground / background moves. JSON lines in Application Support, kept for 14 days.
/// It never leaves the phone and holds no coordinates.
final class PowerLog: @unchecked Sendable {
    enum Kind: String, Codable, Sendable { case gpsOn, gpsOff, launch, foreground, background, refresh, wake, autoStart, wakeIgnored, geofence, repair }

    struct Event: Codable, Equatable, Sendable {
        var time: Date
        var kind: Kind
        var reason: String
    }

    static let keepDays: Double = 14
    static let shared: PowerLog? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return PowerLog(url: dir.appendingPathComponent("power-log.jsonl"))
    }()

    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func log(_ kind: Kind, reason: String = "", at time: Date = Date()) {
        let e = Event(time: time, kind: kind, reason: reason)
        guard var line = try? Self.encoder.encode(e) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url, options: .atomic)
            return
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        }
    }

    func events() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(Event.self, from: Data($0)) }
    }

    /// Drops events older than `keepDays`.
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.keepDays * 86400)
        let all = events()
        let kept = all.filter { $0.time >= cutoff }
        guard kept.count != all.count else { return }
        lock.lock(); defer { lock.unlock() }
        var out = Data()
        for e in kept { if let d = try? Self.encoder.encode(e) { out.append(d); out.append(0x0A) } }
        try? out.write(to: url, options: .atomic)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: maths

    /// Intervals when GPS was on. An interval still open is closed by the next launch (the app
    /// was gone, so GPS was too) or, if none, runs to `now`. A second gpsOn while on is ignored.
    static func gpsIntervals(_ events: [Event], now: Date) -> [DateInterval] {
        var out: [DateInterval] = []
        var open: Date?
        for e in events.sorted(by: { $0.time < $1.time }) {
            switch e.kind {
            case .gpsOn: if open == nil { open = e.time }
            case .gpsOff, .launch:
                if let o = open { out.append(DateInterval(start: o, end: max(o, e.time))); open = nil }
            default: break
            }
        }
        if let o = open { out.append(DateInterval(start: o, end: max(o, now))) }
        return out
    }

    /// Seconds GPS was on during the calendar day holding `day`.
    static func gpsSeconds(_ events: [Event], on day: Date, now: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return gpsIntervals(events, now: now).reduce(0) { sum, i in
            let s = max(i.start, start), e = min(i.end, end)
            return sum + max(0, e.timeIntervalSince(s))
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
