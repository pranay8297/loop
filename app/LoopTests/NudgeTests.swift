import Testing
import Foundation
@testable import Loop

private let tz = TimeZone(identifier: "Asia/Dubai")!
private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
private let en12 = Locale(identifier: "en_US")
private let both = NudgeSettings(nudges: true, recap: true)

/// A date in Dubai. 2026-11-04 is a Wednesday, 2026-11-08 a Sunday.
private func d(_ y: Int, _ mo: Int, _ day: Int, _ h: Int, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(timeZone: tz, year: y, month: mo, day: day, hour: h, minute: mi))!
}

private func w(_ start: Date, minutes: Double = 30, kind: ActivityKind = .walk, km: Double = 2) -> NudgeWorkout {
    NudgeWorkout(start: start, end: start.addingTimeInterval(minutes * 60), seconds: minutes * 60,
                 kind: kind, distanceMeters: km * 1000)
}

/// Walks at hh:mm on each of the `days` days before `today`.
private func history(before today: Date, days: Int, h: Int, mi: Int = 0, kind: ActivityKind = .walk) -> [NudgeWorkout] {
    (1...days).map { k in
        let day = cal.date(byAdding: .day, value: -k, to: cal.startOfDay(for: today))!
        return w(cal.date(bySettingHour: h, minute: mi, second: 0, of: day)!, kind: kind)
    }
}

private func plan(_ ws: [NudgeWorkout], _ now: Date, _ s: NudgeSettings = both, locale: Locale = en12) -> [PlannedNote] {
    NudgePlanner.plan(ws, now: now, calendar: cal, settings: s, locale: locale)
}

@Suite struct NudgePlannerTests {
    @Test func usualWalkGivesNudgeHalfAnHourBefore() {
        let now = d(2026, 11, 4, 12)
        let p = plan(history(before: now, days: 10, h: 19), now)
        let today = p.first { $0.id == "loop.nudge.2026-11-04" }
        #expect(today?.fire == d(2026, 11, 4, 18, 30))
        #expect(today?.title == "Loop")
        #expect(today?.body == "You usually walk around 7 pm. A short loop?")
    }

    @Test func twentyFourHourLocale() {
        let now = d(2026, 11, 4, 12)
        let p = plan(history(before: now, days: 10, h: 18, mi: 40), now, locale: Locale(identifier: "en_GB"))
        #expect(p.first?.body == "You usually walk around 18:30. A short loop?")
    }

    @Test func movedThisMorningMeansNoNudgeToday() {
        let now = d(2026, 11, 4, 12)
        let ws = history(before: now, days: 10, h: 19) + [w(d(2026, 11, 4, 8))]
        let p = plan(ws, now)
        #expect(!p.contains { $0.id == "loop.nudge.2026-11-04" })
        #expect(p.contains { $0.id == "loop.nudge.2026-11-05" }) // tomorrow is still provisional
    }

    @Test func shortWorkoutDoesNotCountAsMoved() {
        let now = d(2026, 11, 4, 12)
        let ws = history(before: now, days: 10, h: 19) + [w(d(2026, 11, 4, 8), minutes: 5)]
        #expect(plan(ws, now).contains { $0.id == "loop.nudge.2026-11-04" })
    }

    @Test func noneAfter2300() {
        let now = d(2026, 11, 4, 12)
        #expect(plan(history(before: now, days: 10, h: 23, mi: 40), now).isEmpty)
    }

    /// A late walker (Dubai evenings): usual 21:30, nudged at 21:00.
    @Test func lateWalkerNudgedAtNine() {
        let now = d(2026, 11, 4, 12)
        let today = plan(history(before: now, days: 10, h: 21, mi: 32), now).first { $0.id == "loop.nudge.2026-11-04" }
        #expect(today?.fire == d(2026, 11, 4, 21, 2))
        #expect(today?.body == "You usually walk around 9:30 pm. A short loop?")
    }

    @Test func noneBefore7am() {
        let now = d(2026, 11, 4, 5)
        let p = plan(history(before: now, days: 10, h: 6, mi: 30), now)
        #expect(!p.contains { $0.id == "loop.nudge.2026-11-04" })
    }

    @Test func noneWithinTwoHoursAfterAWorkout() {
        let now = d(2026, 11, 4, 17)
        // A 5 minute stroll (not "moved") ending at 18:05, 25 min before the 18:30 nudge.
        let ws = history(before: now, days: 10, h: 19) + [w(d(2026, 11, 4, 18), minutes: 5)]
        #expect(!plan(ws, now).contains { $0.id == "loop.nudge.2026-11-04" })
    }

    @Test func pastFireTimeIsSkipped() {
        let now = d(2026, 11, 4, 20)
        #expect(!plan(history(before: now, days: 10, h: 19), now).contains { $0.id == "loop.nudge.2026-11-04" })
    }

    @Test func quietDaysCopy() {
        let now = d(2026, 11, 4, 12)
        // Walked at 19:00 for days 4...12 back, nothing in the last 3 days.
        let ws = history(before: now, days: 12, h: 19).filter { $0.start < d(2026, 11, 1, 0) }
        let today = plan(ws, now).first { $0.id == "loop.nudge.2026-11-04" }
        #expect(today?.body == NudgePlanner.quietBody)
        #expect(today?.fire == d(2026, 11, 4, 18, 30))
    }

    @Test func quietDaysWithoutUsualTimeUses1800() {
        let now = d(2026, 11, 4, 12)
        let ws = [w(d(2026, 10, 20, 9)), w(d(2026, 10, 22, 9))]
        let today = plan(ws, now).first { $0.id == "loop.nudge.2026-11-04" }
        #expect(today?.body == NudgePlanner.quietBody)
        #expect(today?.fire == d(2026, 11, 4, 18, 0))
    }

    @Test func noHistoryAtAllGivesNothing() {
        #expect(plan([], d(2026, 11, 4, 12)).isEmpty)
    }

    @Test func fewerThanFiveActiveDaysGivesNoNormalNudge() {
        let now = d(2026, 11, 4, 12)
        #expect(plan(history(before: now, days: 4, h: 19), now).isEmpty)
    }

    @Test func runCopyWhenMostlyRuns() {
        let now = d(2026, 11, 4, 12)
        let p = plan(history(before: now, days: 6, h: 8, kind: .run), now)
        #expect(p.first?.body == "You usually run around 8 am. A short loop?")
    }

    @Test func sundayGivesOnlyTheRecap() {
        let now = d(2026, 11, 8, 10) // Sunday
        let week = [w(d(2026, 11, 2, 19), minutes: 40, km: 3.2), w(d(2026, 11, 3, 19), minutes: 40, km: 3.2),
                    w(d(2026, 11, 4, 19), minutes: 40, km: 3.0), w(d(2026, 11, 5, 19), minutes: 40, km: 3.0),
                    w(d(2026, 11, 6, 7), minutes: 30, kind: .run, km: 6.0)]
        let p = plan(week + history(before: d(2026, 11, 2, 0), days: 10, h: 19), now)
        let sunday = p.filter { cal.isDate($0.fire, inSameDayAs: now) }
        #expect(sunday.count == 1)
        #expect(sunday.first?.id == "loop.recap.2026-11-08")
        #expect(sunday.first?.fire == d(2026, 11, 8, 19))
        #expect(sunday.first?.title == "Your week")
        // 4 walks and a run, 18.4 km, 3 h 10 min. Not the best: earlier weeks had 7 x 30 min = 3 h 30 min.
        #expect(sunday.first?.body == "4 walks and a run, 18.4 km, 3 h 10 min.")
    }

    @Test func sundayWithRecapOffGetsNudge() {
        let now = d(2026, 11, 8, 10)
        let p = plan(history(before: now, days: 10, h: 19), now, NudgeSettings(nudges: true, recap: false))
        #expect(p.first?.id == "loop.nudge.2026-11-08")
    }

    @Test func bestWeekOnlyWhenTrue() {
        let sunday = d(2026, 11, 8, 0)
        let old = [w(d(2026, 10, 20, 9), minutes: 60), w(d(2026, 10, 27, 9), minutes: 60)]
        let big = [w(d(2026, 11, 3, 9), minutes: 90)]
        #expect(NudgePlanner.recapBody(old + big, sunday: sunday, calendar: cal).hasSuffix(" Your best week yet."))
        let small = [w(d(2026, 11, 3, 9), minutes: 45)]
        #expect(!NudgePlanner.recapBody(old + small, sunday: sunday, calendar: cal).contains("best"))
        // Only one earlier week of history: never "best".
        #expect(!NudgePlanner.recapBody([old[1]] + big, sunday: sunday, calendar: cal).contains("best"))
    }

    @Test func quietWeekCopy() {
        #expect(NudgePlanner.recapBody([w(d(2026, 10, 20, 9))], sunday: d(2026, 11, 8, 0), calendar: cal) == NudgePlanner.quietWeekBody)
        let p = plan([], d(2026, 11, 8, 10))
        #expect(p.first?.body == NudgePlanner.quietWeekBody)
    }

    @Test func bothOffGivesNothing() {
        let now = d(2026, 11, 4, 12)
        #expect(plan(history(before: now, days: 10, h: 19), now, NudgeSettings(nudges: false, recap: false)).isEmpty)
    }

    @Test func noEmDashesInCopy() {
        let now = d(2026, 11, 8, 10)
        let ws = history(before: now, days: 20, h: 19)
        for n in plan(ws, now) + plan(ws, d(2026, 11, 4, 9)) { #expect(!n.body.contains("\u{2014}")) }
    }

    /// Fourteen simulated days, replanning every hour: never two on one day, never at night.
    @Test func fourteenDaysAtMostOneADayNeverAtNight() {
        var ws = history(before: d(2026, 11, 1, 0), days: 14, h: 19)
        var delivered: [String: Date] = [:] // id -> fire, as the latest plan before firing
        var pending: [PlannedNote] = []
        var t = d(2026, 11, 1, 0)
        let end = d(2026, 11, 15, 0)
        var dayIndex = 0
        while t < end {
            // Fire whatever is due.
            for n in pending where n.fire <= t { delivered[n.id] = n.fire }
            pending = plan(ws, t)
            // He walks on even days at 18:00.
            let h = cal.component(.hour, from: t)
            if h == 18, dayIndex % 2 == 0 { ws.append(w(t)) }
            t = t.addingTimeInterval(3600)
            if cal.component(.hour, from: t) == 0 { dayIndex += 1 }
        }
        var perDay: [String: Int] = [:]
        for (_, fire) in delivered {
            perDay[NudgePlanner.key(cal.startOfDay(for: fire), cal), default: 0] += 1
            let m = NudgePlanner.minuteOfDay(fire, cal)
            #expect(m >= 7 * 60 && m <= 23 * 60)
        }
        #expect(perDay.values.allSatisfy { $0 <= 1 })
        #expect(!delivered.isEmpty)
    }
}

// MARK: scheduler

private final class FakeCenter: NotificationCenterLike {
    var authorized = true
    var pending: [String: PlannedNote] = [:]
    func isAuthorized() async -> Bool { authorized }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func removePending(_ ids: [String]) { for i in ids { pending[i] = nil } }
    func add(_ note: PlannedNote) async { pending[note.id] = note }
}

@MainActor
@Suite struct NudgeSchedulerTests {
    fileprivate func make(nudges: Bool = true, recap: Bool = true) -> (NudgeScheduler, FakeCenter, UserDefaults) {
        let defaults = UserDefaults(suiteName: "nudge-tests-\(UUID().uuidString)")!
        defaults.set(nudges, forKey: NudgeScheduler.nudgesKey)
        defaults.set(recap, forKey: NudgeScheduler.recapKey)
        let c = FakeCenter()
        return (NudgeScheduler(center: c, defaults: defaults), c, defaults)
    }

    @Test func replanTwiceLeavesNoDuplicates() async {
        let (s, c, _) = make()
        c.pending["other.app.thing"] = PlannedNote(id: "other.app.thing", fire: Date(), title: "", body: "")
        let now = d(2026, 11, 4, 12)
        let ws = history(before: now, days: 10, h: 19)
        let first = await s.replan(workouts: ws, now: now, calendar: cal)
        await s.replan(workouts: ws, now: now, calendar: cal)
        #expect(!first.isEmpty)
        #expect(c.pending.count == first.count + 1)
        #expect(c.pending["other.app.thing"] != nil)
        #expect(s.nextFire == first.first?.fire)
    }

    @Test func togglingOffRemovesAll() async {
        let (s, c, defaults) = make()
        let now = d(2026, 11, 4, 12)
        let ws = history(before: now, days: 10, h: 19)
        await s.replan(workouts: ws, now: now, calendar: cal)
        #expect(!c.pending.isEmpty)
        defaults.set(false, forKey: NudgeScheduler.nudgesKey)
        defaults.set(false, forKey: NudgeScheduler.recapKey)
        await s.replan(workouts: ws, now: now, calendar: cal)
        #expect(c.pending.isEmpty)
    }

    @Test func notAuthorizedAddsNothing() async {
        let (s, c, _) = make()
        c.authorized = false
        let now = d(2026, 11, 4, 12)
        let out = await s.replan(workouts: history(before: now, days: 10, h: 19), now: now, calendar: cal)
        #expect(out.isEmpty)
        #expect(c.pending.isEmpty)
    }

    @Test func newWorkoutRemovesTodaysNudge() async {
        let (s, c, _) = make()
        let now = d(2026, 11, 4, 12)
        var ws = history(before: now, days: 10, h: 19)
        await s.replan(workouts: ws, now: now, calendar: cal)
        #expect(c.pending["loop.nudge.2026-11-04"] != nil)
        ws.append(w(d(2026, 11, 4, 13)))
        await s.replan(workouts: ws, now: d(2026, 11, 4, 14), calendar: cal)
        #expect(c.pending["loop.nudge.2026-11-04"] == nil)
    }
}
