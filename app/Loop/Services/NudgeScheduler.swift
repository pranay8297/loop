import Foundation
import SwiftData
import UserNotifications
import BackgroundTasks

/// The bits of `UNUserNotificationCenter` Loop uses, so tests can use a fake.
protocol NotificationCenterLike: AnyObject {
    func isAuthorized() async -> Bool
    func pendingIdentifiers() async -> [String]
    func removePending(_ ids: [String])
    func add(_ note: PlannedNote) async
}

final class LiveNotificationCenter: NotificationCenterLike {
    private var center: UNUserNotificationCenter { .current() }

    func isAuthorized() async -> Bool {
        let s = await center.notificationSettings().authorizationStatus
        return s == .authorized || s == .provisional || s == .ephemeral
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }

    func add(_ note: PlannedNote) async {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = .default
        let interval = max(1, note.fire.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: note.id, content: content, trigger: trigger))
    }
}

/// Keeps Loop's pending nudges and recaps in line with the planner. Everything stays on the phone.
@MainActor
final class NudgeScheduler {
    static let nudgesKey = "nudgesOn"
    static let recapKey = "recapOn"
    static let askDoneKey = "nudgeAskDone"
    static let refreshID = "com.pranaybindela.loop.refresh"

    static let shared = NudgeScheduler(center: LiveNotificationCenter())

    let center: NotificationCenterLike
    let defaults: UserDefaults
    /// The next planned fire date, for the background refresh request.
    private(set) var nextFire: Date?

    init(center: NotificationCenterLike, defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    var settings: NudgeSettings {
        NudgeSettings(nudges: defaults.bool(forKey: Self.nudgesKey), recap: defaults.bool(forKey: Self.recapKey))
    }

    static func digests(_ ctx: ModelContext) -> [NudgeWorkout] {
        ((try? ctx.fetch(FetchDescriptor<Workout>())) ?? []).map {
            NudgeWorkout(start: $0.startDate, end: $0.endDate, seconds: $0.durationSeconds,
                         kind: $0.kind, distanceMeters: $0.distanceMeters)
        }
    }

    func replan(_ ctx: ModelContext, now: Date = Date()) async {
        await replan(workouts: Self.digests(ctx), now: now)
    }

    /// Removes Loop's pending requests and adds the planner's. Does nothing without permission.
    @discardableResult
    func replan(workouts: [NudgeWorkout], now: Date = Date(), calendar: Calendar = .current) async -> [PlannedNote] {
        let s = settings
        let mine = await center.pendingIdentifiers().filter {
            $0.hasPrefix(NudgePlanner.nudgePrefix) || $0.hasPrefix(NudgePlanner.recapPrefix)
        }
        if !mine.isEmpty { center.removePending(mine) }
        nextFire = nil
        guard s.anyOn, await center.isAuthorized() else { return [] }
        let plan = NudgePlanner.plan(workouts, now: now, calendar: calendar, settings: s)
        for n in plan { await center.add(n) }
        nextFire = plan.first?.fire
        return plan
    }

    /// Fire and forget, for save hooks.
    /// Reads the store now, so the task never touches the context later.
    func replanSoon(_ ctx: ModelContext) {
        let ws = settings.anyOn ? Self.digests(ctx) : []
        Task { await replan(workouts: ws) }
    }

    /// Asks the system to wake Loop shortly before the next nudge, so it can be checked again.
    func submitRefresh(now: Date = Date()) {
        guard settings.anyOn else { return }
        let earliest = nextFire.map { max(now.addingTimeInterval(60), $0.addingTimeInterval(-45 * 60)) }
            ?? now.addingTimeInterval(3 * 3600)
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        req.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(req)
    }

    /// Background refresh: motion scan, replan, ask for the next one. No GPS.
    static func runRefresh(container: ModelContainer) async {
        PowerLog.shared?.log(.refresh)
        let ctx = container.mainContext
        await MotionHistory.shared.scanIfDue(ctx)
        await shared.replan(ctx)
        shared.submitRefresh()
    }

    /// Asks for permission (alert, sound). Returns whether it was granted.
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    #if DEBUG
    /// `-LoopTestNudge`: a real nudge 10 s from now with the planner's copy.
    static func scheduleTestNudge(_ ctx: ModelContext) async {
        guard await requestAuthorization() else { return }
        let ws = digests(ctx)
        let today = Calendar.current.startOfDay(for: Date())
        let body: String
        if let u = NudgePlanner.usualTime(ws, today: today, calendar: .current) {
            body = "You usually \(NudgePlanner.verb(u.kind)) around \(NudgePlanner.clock(NudgePlanner.roundHalfHour(u.minute), locale: .current)). A short loop?"
        } else {
            body = NudgePlanner.quietBody
        }
        await LiveNotificationCenter().add(PlannedNote(id: "loop.test", fire: Date().addingTimeInterval(10),
                                                       title: "Loop", body: body))
    }
    #endif
}
