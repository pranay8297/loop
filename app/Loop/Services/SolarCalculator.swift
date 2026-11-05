import Foundation

/// NOAA general solar position approximation. Offline and pure.
enum SolarCalculator {
    struct Times: Sendable { let sunrise: Date; let sunset: Date }

    static func times(latitude: Double, longitude: Double, date: Date, timeZone: TimeZone) -> Times? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let localMidnight = cal.date(from: comps) else { return nil }
        let dayOfYear = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)

        func event(rising: Bool) -> Date? {
            // Iterate once to refine the fractional-year by event time.
            var minutesUTC = 720.0
            for _ in 0..<2 {
                let gamma = 2 * Double.pi / 365 * (dayOfYear - 1 + (minutesUTC / 60 - 12) / 24)
                let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                                       - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
                let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
                    - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
                    - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
                let lat = latitude * .pi / 180
                let cosHA = cos(90.833 * .pi / 180) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
                guard cosHA >= -1, cosHA <= 1 else { return nil }
                let ha = acos(cosHA) * 180 / .pi
                minutesUTC = 720 - 4 * (longitude + (rising ? ha : -ha)) - eqTime
            }
            // UTC midnight of the same calendar date
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
            guard let utcMidnight = utc.date(from: comps) else { return nil }
            var d = utcMidnight.addingTimeInterval(minutesUTC * 60)
            // keep the event on the local calendar day
            if d < localMidnight { d.addTimeInterval(86400) }
            if d >= localMidnight.addingTimeInterval(86400) { d.addTimeInterval(-86400) }
            return d
        }
        guard let r = event(rising: true), let s = event(rising: false) else { return nil }
        return Times(sunrise: r, sunset: s)
    }
}
