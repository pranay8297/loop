import SwiftUI
import SwiftData
import CoreMotion

struct YouView: View {
    @Query(sort: \Workout.startDate, order: .reverse) private var workouts: [Workout]
    @State private var showSettings = false
    @State private var motionAsk = false
    @AppStorage(MotionHistory.enabledKey) private var autoLog = true
    @Environment(\.modelContext) private var ctx

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            MonoLabel(workouts.last.map { "Since " + Format.dayLabel($0.startDate) } ?? "Loop")
                            TitleText(text: "You")
                        }
                        Spacer()
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").font(.system(size: 16)).foregroundStyle(Theme.dim)
                                .frame(width: 34, height: 34).background(Circle().fill(Theme.surface1))
                        }
                        .accessibilityIdentifier("settingsButton")
                    }
                    if motionAsk {
                        motionRow.padding(.top, 18)
                    }
                    if workouts.isEmpty {
                        Text("Your workouts will show up here.").font(.system(size: 14)).foregroundStyle(Theme.dim)
                            .padding(.top, 30)
                    } else {
                        totals.padding(.top, 18)
                        MonthGrid(workouts: workouts).padding(.top, 18)
                        list.padding(.top, 18)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.ink)
            .navigationDestination(for: Workout.self) { w in SummaryView(workout: w) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear(perform: refreshMotionAsk)
            .onChange(of: autoLog) { refreshMotionAsk() }
        }
    }

    private func refreshMotionAsk() {
        motionAsk = autoLog && CMMotionActivityManager.isActivityAvailable()
            && CMMotionActivityManager.authorizationStatus() == .notDetermined
    }

    /// Shown once, until motion access is decided.
    private var motionRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log walks without pressing start").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.paper)
                Text("Reads your iPhone's motion record. No GPS.").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Button("Turn on") {
                LiveMotionHistory.requestAccess {
                    refreshMotionAsk()
                    Task { await MotionHistory.shared.scan(ctx) }
                }
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Theme.paper))
            .accessibilityIdentifier("motionTurnOn")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface1))
    }

    private var totals: some View {
        let runs = workouts.filter { $0.kind == .run && !$0.isCheckIn }
        let km = runs.reduce(0) { $0 + $1.distanceMeters } / 1000
        let walks = workouts.filter { $0.kind == .walk }
        let rides = workouts.filter { $0.kind == .ride }
        let swims = workouts.filter { $0.kind == .swim }.count
        let gyms = workouts.filter { $0.kind == .gym }.count
        var cells: [(String, String)] = [(String(format: "%.1f", km), "run km · \(runs.count) runs")]
        if !walks.isEmpty { cells.append((String(format: "%.1f", walks.reduce(0) { $0 + $1.distanceMeters } / 1000), "walk km")) }
        let rideKm = rides.reduce(0) { $0 + $1.distanceMeters } / 1000
        // Rides picked up from motion history have no distance, so count them instead.
        if !rides.isEmpty {
            cells.append(rideKm > 0 ? (String(format: "%.1f", rideKm), "ride km") : ("\(rides.count)", rides.count == 1 ? "ride" : "rides"))
        }
        if swims > 0 { cells.append(("\(swims)", "swims")) }
        if gyms > 0 { cells.append(("\(gyms)", "gym days")) }
        return HStack(alignment: .top) {
            ForEach(Array(cells.prefix(4).enumerated()), id: \.offset) { _, c in StatCell(value: c.0, unit: c.1, size: 24) }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(workouts) { w in
                NavigationLink(value: w) {
                    HStack(spacing: 12) {
                        Image(systemName: w.kind.symbol).font(.system(size: 15)).foregroundStyle(Theme.paper)
                            .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface1))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.paper).lineLimit(1)
                            Text(rowMeta(w)).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workoutRow")
                .contextMenu {
                    if w.isDetected {
                        Button("Not a workout", systemImage: "xmark") { MotionHistory.shared.dismiss(w, in: ctx) }
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
    }

    private func rowMeta(_ w: Workout) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(w.startDate) { day = "Today" }
        else if cal.isDateInYesterday(w.startDate) { day = "Yesterday" }
        else if Date().timeIntervalSince(w.startDate) < 6 * 86400 {
            let f = DateFormatter(); f.dateFormat = "EEE"; day = f.string(from: w.startDate)
        } else { day = Format.dayLabel(w.startDate) }
        if w.isCheckIn { return "\(day) · check-in · \(Int(w.durationSeconds / 60)) min" }
        if w.isDetected {
            if w.kind == .ride || w.distanceMeters <= 0 { return [day, Format.duration(w.movingSeconds), "auto"].joined(separator: " · ") }
            return [day, Format.km(w.distanceMeters) + " km", Format.duration(w.movingSeconds), "auto"].joined(separator: " · ")
        }
        var parts = [day, Format.km(w.distanceMeters) + " km", Format.duration(w.movingSeconds)]
        if w.kind == .run, w.walkMeters > 0, let f = w.runFraction { parts.append("ran \(Int((f * 100).rounded()))%") }
        return parts.joined(separator: " · ")
    }
}

/// Four weeks, Monday first. Run dot size scales with km.
struct MonthGrid: View {
    let workouts: [Workout]
    var body: some View {
        let cal = mondayCalendar
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = cal.date(byAdding: .day, value: -21, to: thisWeek)!
        let days = (0..<28).map { cal.date(byAdding: .day, value: $0, to: start)! }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MonoLabel("\(Format.dayLabel(start)) to \(Format.dayLabel(days.last!))")
                Spacer()
                MonoLabel("● Run ○ Swim ■ Gym")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.dim)
                }
                ForEach(days, id: \.self) { d in
                    let dayWs = workouts.filter { cal.isDate($0.startDate, inSameDayAs: d) }
                    let km = dayWs.filter { $0.kind.isGPS }.reduce(0) { $0 + $1.distanceMeters } / 1000
                    let kind = dayWs.first(where: { $0.kind.isGPS })?.kind ?? dayWs.first?.kind
                    ZStack {
                        Circle().fill(Theme.surface1)
                        if cal.isDate(d, inSameDayAs: today) { Circle().strokeBorder(Theme.accent, lineWidth: 1.2) }
                        DayMark(kind: kind, size: kind?.isGPS == true ? min(18, 6 + km * 1.6) : 8)
                    }
                    .frame(width: 30, height: 30)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface1))
    }
}

struct SettingsView: View {
    @AppStorage("usePlaces") private var usePlaces = true
    @AppStorage("saveToHealth") private var saveToHealth = true
    @AppStorage(MotionHistory.enabledKey) private var autoLog = true
    @AppStorage(NudgeScheduler.nudgesKey) private var nudgesOn = false
    @AppStorage(NudgeScheduler.recapKey) private var recapOn = false
    @State private var notesDenied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx

    private static let deniedNote = "Notifications are off for Loop. Allow them for Loop in the Settings app."

    private func notesChanged(_ on: Bool) {
        Task {
            if on, await NudgeScheduler.authorizationStatus() == .notDetermined {
                _ = await NudgeScheduler.requestAuthorization()
            }
            notesDenied = await NudgeScheduler.authorizationStatus() == .denied
            await NudgeScheduler.shared.replan(ctx)
        }
    }

    private var motionNote: String {
        switch CMMotionActivityManager.authorizationStatus() {
        case .denied, .restricted:
            return "Motion & Fitness is off for Loop. Turn it on in the Settings app to use this."
        default:
            return "Reads your iPhone's motion record when you open Loop. No GPS, no extra battery."
        }
    }

    var body: some View {
        NavigationStack {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TitleText(text: "Settings", size: 22)
                Spacer()
                Button("Done") { dismiss() }.font(.system(size: 15, weight: .semibold))
            }
            Toggle(isOn: $usePlaces) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use place names").font(.system(size: 15, weight: .semibold))
                    Text("Looks up the area you went, to name workouts. The only thing Loop sends off your phone.")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
            }
            .tint(Theme.accent)
            .padding(.top, 22)
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 14)
            Toggle(isOn: $saveToHealth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save to Apple Health").font(.system(size: 15, weight: .semibold))
                    Text("Workouts and routes, written after each save.").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
            }
            .tint(Theme.accent)
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 14)
            Toggle(isOn: $autoLog) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log walks and runs by itself").font(.system(size: 15, weight: .semibold))
                    Text(motionNote).font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("autoLogToggle")
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 14)
            Toggle(isOn: $nudgesOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nudges").font(.system(size: 15, weight: .semibold))
                    Text(notesDenied && nudgesOn ? Self.deniedNote : "One a day at most, a little before your usual time, only if you haven't moved yet.")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("nudgesToggle")
            .onChange(of: nudgesOn) { _, on in notesChanged(on) }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 14)
            Toggle(isOn: $recapOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sunday recap").font(.system(size: 15, weight: .semibold))
                    Text(notesDenied && recapOn ? Self.deniedNote : "Your week in one line, Sunday at 7 pm.")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.accent)
            .accessibilityIdentifier("recapToggle")
            .onChange(of: recapOn) { _, on in notesChanged(on) }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 14)
            NavigationLink {
                DiagnosticsView()
            } label: {
                HStack {
                    Text("Battery and diagnostics").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diagnosticsRow")
            Spacer()
        }
        .padding(20)
        .foregroundStyle(Theme.paper)
        .background(Theme.ink)
        .toolbar(.hidden, for: .navigationBar)
        }
        .task { notesDenied = await NudgeScheduler.authorizationStatus() == .denied }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.ink)
    }
}
