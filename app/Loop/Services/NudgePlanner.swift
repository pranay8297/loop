import Foundation

/// What the planner needs from a workout. Built from `Workout` so the planner stays pure.
struct NudgeWorkout: Equatable, Sendable {
    var start: Date
    var end: Date
    /// Moving time, or the duration for a check-in.
    var seconds: Double
    var kind: ActivityKind
    var distanceMeters: Double
}

struct NudgeSettings: Equatable, Sendable {
    var nudges: Bool
    var recap: Bool
    var anyOn: Bool { nudges || recap }
}

/// One local notification Loop wants pending.
struct PlannedNote: Equatable, Sendable {
    var id: String
    var fire: Date
    var title: String
    var body: String
}

/// Decides which nudges and recaps to keep pending, from the user's own history only.
/// Pure: no clock, no notification centre, no store.
enum NudgePlanner {
    static let nudgePrefix = "loop.nudge."
    static let recapPrefix = "loop.recap."

    static let movedSeconds: Double = 10 * 60
    static let lookbackDays = 28
    static let minActiveDays = 5
    static let offsetMinutes = 20
    static let earliestMinute = 7 * 60
    static let latestMinute = 21 * 60 + 30
    static let afterMoveGap: TimeInterval = 2 * 3600
    static let quietDays = 3
    static let quietFallbackMinute = 18 * 60
    static let recapMinute = 19 * 60

    static let quietBody = "Three quiet days. A 20 minute walk keeps your week going."
    static let quietWeekBody = "A quiet week. The next one starts tomorrow."

    /// Notifications to have pending for today and tomorrow, sorted by fire date.
    static func plan(_ workouts: [NudgeWorkout], now: Date, calendar: Calendar = .current,
                     settings: NudgeSettings, locale: Locale = .current) -> [PlannedNote] {
        guard settings.anyOn else { return [] }
        let today = calendar.startOfDay(for: now)
        let usual = usualTime(workouts, today: today, calendar: calendar)
        var out: [PlannedNote] = []
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let isSunday = calendar.component(.weekday, from: day) == 1
            if settings.recap, isSunday {
                if let fire = at(recapMinute, on: day, calendar), fire > now {
                    out.append(PlannedNote(id: recapPrefix + key(day, calendar), fire: fire, title: "Your week",
                                           body: recapBody(workouts, sunday: day, calendar: calendar)))
                }
                continue // one a day at most
            }
            guard settings.nudges else { continue }
            if let n = nudge(workouts, day: day, now: now, usual: usual, calendar: calendar, locale: locale) {
                out.append(n)
            }
        }
        return out.sorted { $0.fire < $1.fire }
    }

    // MARK: daily nudge

    static func nudge(_ ws: [NudgeWorkout], day: Date, now: Date, usual: (minute: Int, kind: ActivityKind?)?,
                      calendar: Calendar, locale: Locale) -> PlannedNote? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        // Moved that day already: nothing to nudge.
        if ws.contains(where: { $0.seconds >= movedSeconds && $0.start >= day && $0.start < next }) { return nil }
        let quiet = isQuiet(ws, before: day, calendar: calendar)
        let minute: Int
        let body: String
        if quiet {
            minute = (usual?.minute ?? quietFallbackMinute) + offsetMinutes
            body = quietBody
        } else if let u = usual {
            minute = u.minute + offsetMinutes
            body = "You usually \(verb(u.kind)) around \(clock(roundHalfHour(u.minute), locale: locale)). A short loop?"
        } else {
            return nil
        }
        guard minute >= earliestMinute, minute <= latestMinute,
              let fire = at(minute, on: day, calendar), fire > now else { return nil }
        // Never right after moving.
        if ws.contains(where: { $0.end <= fire && fire.timeIntervalSince($0.end) < afterMoveGap }) { return nil }
        return PlannedNote(id: nudgePrefix + key(day, calendar), fire: fire, title: "Loop", body: body)
    }

    /// No moved day in the `quietDays` full days before `day`. Needs some history, so a brand new
    /// user is never told they have been quiet.
    static func isQuiet(_ ws: [NudgeWorkout], before day: Date, calendar: Calendar) -> Bool {
        guard let from = calendar.date(byAdding: .day, value: -quietDays, to: day) else { return false }
        guard ws.contains(where: { $0.start < from }) else { return false }
        return !ws.contains(where: { $0.seconds >= movedSeconds && $0.start >= from && $0.start < day })
    }

    /// Median start (minute of day) of each active day's longest workout over the last 28 days,
    /// and the most common of walk / run / ride among them. Nil with fewer than 5 active days.
    static func usualTime(_ ws: [NudgeWorkout], today: Date, calendar: Calendar) -> (minute: Int, kind: ActivityKind?)? {
        guard let from = calendar.date(byAdding: .day, value: -lookbackDays, to: today) else { return nil }
        var longest: [Date: NudgeWorkout] = [:]
        for w in ws where w.seconds >= movedSeconds && w.start >= from && w.start < today {
            let d = calendar.startOfDay(for: w.start)
            if let cur = longest[d], cur.seconds >= w.seconds { continue }
            longest[d] = w
        }
        guard longest.count >= minActiveDays else { return nil }
        let minutes = longest.values.map { minuteOfDay($0.start, calendar) }.sorted()
        let n = minutes.count
        let median = n % 2 == 1 ? minutes[n / 2] : (minutes[n / 2 - 1] + minutes[n / 2]) / 2
        var counts: [ActivityKind: Int] = [:]
        for w in longest.values where [.walk, .run, .ride].contains(w.kind) { counts[w.kind, default: 0] += 1 }
        let order: [ActivityKind] = [.walk, .run, .ride]
        let kind = counts.max { a, b in
            a.value != b.value ? a.value < b.value
                : (order.firstIndex(of: a.key) ?? 0) > (order.firstIndex(of: b.key) ?? 0)
        }?.key
        return (median, kind)
    }

    // MARK: Sunday recap

    static func recapBody(_ ws: [NudgeWorkout], sunday: Date, calendar: Calendar) -> String {
        let weekStart = mondayStart(sunday, calendar)
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return quietWeekBody }
        let week = ws.filter { $0.start >= weekStart && $0.start < weekEnd }
        guard !week.isEmpty else { return quietWeekBody }
        var counts: [ActivityKind: Int] = [:]
        for w in week { counts[w.kind, default: 0] += 1 }
        let order = ActivityKind.allCases
        let parts = counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : order.firstIndex(of: a.key)! < order.firstIndex(of: b.key)!
        }.map { countPhrase($0.key, $0.value) }
        var pieces = [list(parts)]
        let meters = week.reduce(0) { $0 + $1.distanceMeters }
        if meters >= 100 { pieces.append(String(format: "%.1f km", meters / 1000)) }
        let seconds = week.reduce(0) { $0 + $1.seconds }
        pieces.append(duration(seconds))
        var body = pieces.joined(separator: ", ") + "."
        if isBestWeek(ws, weekStart: weekStart, seconds: seconds, calendar: calendar) { body += " Your best week yet." }
        return body
    }

    /// Most moving time of any Monday to Sunday week, with at least two earlier weeks of history.
    static func isBestWeek(_ ws: [NudgeWorkout], weekStart: Date, seconds: Double, calendar: Calendar) -> Bool {
        guard seconds > 0, let first = ws.map(\.start).min(),
              let twoBack = calendar.date(byAdding: .day, value: -14, to: weekStart),
              mondayStart(first, calendar) <= twoBack else { return false }
        var totals: [Date: Double] = [:]
        for w in ws where w.start < weekStart { totals[mondayStart(w.start, calendar), default: 0] += w.seconds }
        return totals.values.allSatisfy { seconds > $0 }
    }

    static func countPhrase(_ k: ActivityKind, _ n: Int) -> String {
        let (one, many): (String, String) = switch k {
        case .run: ("a run", "runs")
        case .walk: ("a walk", "walks")
        case .ride: ("a ride", "rides")
        case .swim: ("a swim", "swims")
        case .gym: ("a gym session", "gym sessions")
        }
        return n == 1 ? one : "\(n) \(many)"
    }

    static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r) min" }
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    // MARK: helpers

    static func verb(_ k: ActivityKind?) -> String {
        switch k {
        case .run: "run"
        case .ride: "ride"
        case .walk: "walk"
        default: "move"
        }
    }

    static func roundHalfHour(_ minute: Int) -> Int { Int((Double(minute) / 30).rounded()) * 30 }

    /// "7 pm", "7:30 pm" or "19:00", "19:30", following the locale's 12 or 24 hour style.
    static func clock(_ minute: Int, locale: Locale) -> String {
        let h = (minute / 60) % 24, m = minute % 60
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h a"
        if pattern.contains("H") || pattern.contains("k") { return String(format: "%02d:%02d", h, m) }
        let h12 = h % 12 == 0 ? 12 : h % 12
        let suffix = h < 12 ? "am" : "pm"
        return m == 0 ? "\(h12) \(suffix)" : String(format: "%d:%02d %@", h12, m, suffix)
    }

    static func minuteOfDay(_ d: Date, _ cal: Calendar) -> Int {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func at(_ minute: Int, on day: Date, _ cal: Calendar) -> Date? {
        cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }

    static func mondayStart(_ d: Date, _ cal: Calendar) -> Date {
        var c = cal; c.firstWeekday = 2
        return c.dateInterval(of: .weekOfYear, for: d)?.start ?? c.startOfDay(for: d)
    }

    static func key(_ day: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
