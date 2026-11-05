import Foundation

struct NamingInput: Sendable {
    var start: Date
    var timeZone: TimeZone
    var latitude: Double?
    var longitude: Double?
    var place: String?
    var shape: RouteShape
    var kind: ActivityKind
    var hasWalkSegments: Bool
    var highlights: [Highlight]
    var isCheckIn: Bool = false
}

protocol WorkoutNamer: Sendable {
    func name(for input: NamingInput) async -> (name: String, reason: String)
}

/// Rule-based namer. Runs on the phone, no model, no network.
struct RuleBasedNamer: WorkoutNamer {
    enum TimeWord: String, Sendable {
        case sunrise = "Sunrise", sunset = "Sunset", morning = "Morning", midday = "Midday"
        case afternoon = "Afternoon", evening = "Evening", late = "Late", midnight = "Midnight"
        var isSpecial: Bool { self == .sunrise || self == .sunset || self == .late || self == .midnight }
    }

    func name(for input: NamingInput) async -> (name: String, reason: String) { compose(input) }

    static func timeWord(start: Date, timeZone: TimeZone, latitude: Double?, longitude: Double?) -> (TimeWord, SolarCalculator.Times?) {
        var solar: SolarCalculator.Times?
        if let lat = latitude, let lon = longitude {
            solar = SolarCalculator.times(latitude: lat, longitude: lon, date: start, timeZone: timeZone)
            if let s = solar {
                if start >= s.sunrise.addingTimeInterval(-40 * 60), start <= s.sunrise.addingTimeInterval(45 * 60) { return (.sunrise, s) }
                if abs(start.timeIntervalSince(s.sunset)) <= 40 * 60 { return (.sunset, s) }
            }
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let h = cal.component(.hour, from: start)
        let w: TimeWord = switch h {
        case 4..<11: .morning
        case 11..<14: .midday
        case 14..<17: .afternoon
        case 17..<21: .evening
        case 21..<24: .late
        default: .midnight
        }
        return (w, solar)
    }

    static func noun(kind: ActivityKind, shape: RouteShape, hasWalk: Bool) -> String {
        switch kind {
        case .run:
            switch shape {
            case .loop: return "loop"
            case .outAndBack: return hasWalk ? "run-walk" : "out-and-back"
            case .pointToPoint: return hasWalk ? "run-walk" : "run"
            }
        case .walk: return shape == .loop ? "walk loop" : "walk"
        case .ride: return "ride"
        case .swim: return "swim"
        case .gym: return "gym"
        }
    }

    /// "Saadiyat Island" -> "Saadiyat". Keeps names like "Kite Beach" and "Al Barsha".
    static func cleanPlace(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let generic = [" Island", " District", " Area", " Community", " Neighbourhood", " Neighborhood"]
        for g in generic where s.lowercased().hasSuffix(g.lowercased()) && s.count > g.count {
            s = String(s.dropLast(g.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return s.isEmpty ? nil : s
    }

    func compose(_ input: NamingInput) -> (name: String, reason: String) {
        let place = Self.cleanPlace(input.place)
        let (word, solar) = Self.timeWord(start: input.start, timeZone: input.timeZone,
                                          latitude: input.latitude, longitude: input.longitude)
        let noun = Self.noun(kind: input.kind, shape: input.shape, hasWalk: input.hasWalkSegments)
        let setOff = Format.clock(input.start, tz: input.timeZone)

        if !input.isCheckIn, let h = input.highlights.compactMap({ hl in hl.namePhrase.map { (hl, $0) } }).first {
            let name = place.map { "\(h.1), \($0)" } ?? h.1
            var reason = "Named on your iPhone"
            if let place { reason += " from where you went: \(place)." } else { reason += "." }
            reason += " " + highlightReason(h.0)
            return (name, reason)
        }

        let name: String
        if let place {
            name = word.isSpecial ? "\(place) \(word.rawValue.lowercased()) \(noun)" : "\(place) \(noun)"
        } else {
            name = "\(word.rawValue) \(noun)"
        }

        var reason = "Named on your iPhone"
        if let place {
            reason += " from where you went: \(place)"
            if word == .sunrise { reason += ", at sunrise" }
            if word == .sunset { reason += ", at sunset" }
            reason += "."
        } else {
            reason += "."
        }
        if let solar, word == .sunrise {
            reason += " You set off at \(setOff), sunrise was \(Format.clock(solar.sunrise, tz: input.timeZone))."
        } else if let solar, word == .sunset {
            reason += " You set off at \(setOff), sunset was \(Format.clock(solar.sunset, tz: input.timeZone))."
        } else {
            reason += " You set off at \(setOff)."
        }
        switch input.shape {
        case .loop where input.kind.isGPS: reason += " It ended where it started."
        case .outAndBack where input.kind.isGPS: reason += " You went out and came back the same way."
        default: break
        }
        return (name, reason)
    }

    private func highlightReason(_ h: Highlight) -> String {
        switch h {
        case .firstOfKind(let k): "This is your first \(k.noun) on Loop."
        case .first5KNoWalk: "5 km or more, and you ran all of it."
        case .longest(let k, _): "Your longest \(k.noun) so far."
        case .fastestKm(let s): "Your quickest kilometre so far, \(Format.pace(s)) per km."
        case .ranFraction: ""
        }
    }
}
