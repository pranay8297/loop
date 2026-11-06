import SwiftUI
import SwiftData

struct StartView: View {
    let session: Session
    let env: DeviceEnvironmentProvider
    @Query(sort: \Workout.startDate, order: .reverse) private var workouts: [Workout]
    @AppStorage("lastKind") private var lastKindRaw = ActivityKind.run.rawValue
    @State private var checkInKind: ActivityKind?
    @State private var routes: [[RoutePoint]] = []
    @State private var heat: [PersonalHeat.Cell] = []
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var ctx
    @AppStorage(NudgeScheduler.askDoneKey) private var nudgeAskDone = false
    @AppStorage(NudgeScheduler.nudgesKey) private var nudgesOn = false
    @AppStorage(NudgeScheduler.recapKey) private var recapOn = false

    private var kind: ActivityKind { ActivityKind(rawValue: lastKindRaw) ?? .run }
    private var capability: Capability { CapabilityChecker.decide(kind: kind, env: env.env) }

    var body: some View {
        ZStack {
            HomeMapBackground(routes: routes, heat: heat, lastKnown: env.lastKnownLocation)
            content
        }
        .background(Theme.ink)
        .task(id: RoutesKey(count: workouts.count, latest: workouts.first?.startDate)) { await loadRoutes() }
        .sheet(item: $checkInKind) { k in
            CheckInView(kind: k, capability: CapabilityChecker.decide(kind: k, env: env.env),
                        lastKnown: env.lastKnownLocation) { msg in session.toast = msg }
        }
    }

    private struct RoutesKey: Equatable { var count: Int; var latest: Date? }

    /// Decoded and binned off the main thread, only when the workouts change.
    private func loadRoutes() async {
        let data = workouts.filter { $0.source == "recorded" && !$0.isCheckIn }.compactMap(\.routeData)
        let (r, h) = await Task.detached(priority: .utility) {
            let all = data.compactMap { try? JSONDecoder().decode([RoutePoint].self, from: $0) }.filter { !$0.isEmpty }
            return (all, PersonalHeat.counts(all))
        }.value
        routes = r; heat = h
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MonoLabel(Format.dayLabel(Date()), color: Theme.dim)
                TitleText(text: greeting).padding(.top, 4)
                WeekCard(workouts: workouts).padding(.top, 18)
                chips.padding(.top, 24)
                startButton.padding(.top, 26)
                note.padding(.top, 22)
                if !nudgeAskDone && workouts.count >= 3 {
                    NudgeAskCard(yes: askYes, notNow: { withAnimation { nudgeAskDone = true } })
                        .padding(.top, 22)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 4 && h < 12 ? "Morning" : h >= 12 && h < 17 ? "Afternoon" : "Evening"
    }

    private var chips: some View {
        HStack(spacing: 5) {
            ForEach(ActivityKind.allCases) { k in
                Button { lastKindRaw = k.rawValue } label: {
                    Label(k.displayName, systemImage: k.symbol).labelStyle(ChipLabelStyle())
                }
                .buttonStyle(ChipStyle(selected: k == kind))
                .accessibilityIdentifier("sport-\(k.rawValue)")
                .accessibilityAddTraits(k == kind ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var startButton: some View {
        let canTrack = capability.canTrack
        return ZStack {
            Circle().strokeBorder(Theme.hairline, lineWidth: 1).frame(width: 178, height: 178)
            Button {
                if canTrack { start() } else { checkInKind = kind }
            } label: {
                VStack(spacing: 3) {
                    Text(canTrack ? "Start" : "Check in").font(.system(size: 26, weight: .semibold)).tracking(-1)
                    if canTrack { Text(kind.startSubtitle).font(.system(size: 12, weight: .medium)).opacity(0.6) }
                }
                .foregroundStyle(canTrack ? Theme.ink : Theme.paper)
                .frame(width: 146, height: 146)
                .background(Circle().fill(canTrack ? Theme.paper : Color.clear))
                .overlay(Circle().strokeBorder(canTrack ? Color.clear : Theme.paper, lineWidth: 1.5))
                .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .accessibilityIdentifier(canTrack ? "startButton" : "checkInButton")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var note: some View {
        switch capability {
        case .track(let n):
            NoteRow(filled: true, title: nil, detail: n)
        case .trackLimited(let n):
            NoteRow(filled: false, title: nil, detail: n)
        case .cannotTrack(let title, let detail, let actions):
            VStack(alignment: .leading, spacing: 10) {
                NoteRow(filled: false, title: title, detail: detail)
                if actions.contains(.openSettings) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .padding(.leading, 16)
                }
            }
        }
    }

    private func askYes() {
        Task {
            let granted = await NudgeScheduler.requestAuthorization()
            if granted { nudgesOn = true; recapOn = true }
            withAnimation { nudgeAskDone = true }
            await NudgeScheduler.shared.replan(ctx)
        }
    }

    private func start() {
        if env.env.locationAuth == .notDetermined { env.requestWhenInUse() }
        let r = LaunchOptions.makeRecorder()
        r.start(kind: kind)
        session.saved = nil
        session.recorder = r
        session.showingCover = true
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 11)); configuration.title.lineLimit(1) }.fixedSize()
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Asked once: would a nudge on quiet days help?
struct NudgeAskCard: View {
    let yes: () -> Void
    let notNow: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Want a nudge on quiet days?").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.paper)
            Text("One a day at most, around when you usually move. Never at night.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineSpacing(2)
            HStack(spacing: 16) {
                Button(action: yes) {
                    Text("Yes").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(Capsule().fill(Theme.paper))
                }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("nudgeYes")
                Button(action: notNow) {
                    Text("Not now").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.dim)
                }
                .accessibilityIdentifier("nudgeNotNow")
            }
            .padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface1))
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.ink.opacity(0.85)))
    }
}

struct NoteRow: View {
    let filled: Bool
    let title: String?
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if filled { AccentDot() } else { Circle().strokeBorder(Theme.paper, lineWidth: 1.4).frame(width: 7, height: 7) }
            }
            .padding(.top, 5)
            (title.map { Text($0 + ". ").foregroundStyle(Theme.paper).fontWeight(.semibold) } ?? Text(""))
                + Text(detail).foregroundStyle(Theme.dim)
        }
        .font(.system(size: 12.5))
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deviceNote")
    }
}

struct WeekCard: View {
    let workouts: [Workout]

    var body: some View {
        let cal = mondayCalendar
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: weekStart)! }
        let inWeek = workouts.filter { $0.startDate >= weekStart && $0.startDate < cal.date(byAdding: .day, value: 7, to: weekStart)! }
        let seconds = inWeek.reduce(0) { $0 + $1.durationSeconds }
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                MonoLabel("This week")
                Spacer()
                Text(Format.hoursMinutes(seconds)).font(Theme.number(20)).foregroundStyle(Theme.paper)
                    .accessibilityIdentifier("weekTime")
                Text("\(inWeek.count) workout\(inWeek.count == 1 ? "" : "s")").font(.system(size: 13)).foregroundStyle(Theme.dim)
                    .accessibilityIdentifier("weekCount")
            }
            HStack {
                ForEach(days, id: \.self) { d in
                    let isToday = cal.isDate(d, inSameDayAs: today)
                    let k = inWeek.first(where: { cal.isDate($0.startDate, inSameDayAs: d) })?.kind
                    VStack(spacing: 6) {
                        Text(String(Format.weekdayLetter(d))).font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(isToday ? Theme.paper : Theme.dim)
                        ZStack {
                            Circle().fill(Theme.surface1)
                            if isToday { Circle().strokeBorder(Theme.paper, lineWidth: 1.2) }
                            DayMark(kind: k)
                        }
                        .frame(width: 26, height: 26)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface1))
    }
}

var mondayCalendar: Calendar {
    var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.timeZone = .current; return c
}

extension Format {
    static func weekdayLetter(_ d: Date) -> Character {
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f.string(from: d).first ?? " "
    }
}
