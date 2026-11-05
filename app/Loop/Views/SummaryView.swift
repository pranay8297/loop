import SwiftUI
import SwiftData
import MapKit

struct SummaryView: View {
    @Bindable var workout: Workout
    var justSaved = false
    var onDone: (() -> Void)?
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var showShare = false
    @State private var highlights: [Highlight] = []
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                savedRow
                nameView.padding(.top, 14)
                Text(meta).font(.system(size: 12)).foregroundStyle(Theme.dim).padding(.top, 6)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Theme.dim).padding(.top, 1)
                    Text(workout.nameReason).font(.system(size: 12)).foregroundStyle(Theme.dim).lineSpacing(2)
                }
                .padding(.top, 12)
                if !workout.isCheckIn {
                    if workout.route.count > 1 { RouteCard(workout: workout).padding(.top, 14) }
                    if workout.kind == .run, !workout.segments.isEmpty { runWalk.padding(.top, 14) }
                    stats.padding(.top, 18)
                    if !highlights.isEmpty { chips.padding(.top, 16) }
                    splits.padding(.top, 18)
                }
                actions.padding(.top, 22)
                if onDone == nil { deleteRow.padding(.top, 26) }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Theme.ink)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDone() }.accessibilityIdentifier("doneButton")
                }
            }
        }
        .sheet(isPresented: $showShare) { ShareScreen(workout: workout) }
        .task { computeHighlights() }
    }

    private func computeHighlights() {
        // Only workouts before this one count as history.
        let earlier = ((try? ctx.fetch(FetchDescriptor<Workout>())) ?? [])
            .filter { $0.id != workout.id && $0.startDate < workout.startDate }
            .map { WorkoutDigest(kind: $0.kind, distanceMeters: $0.distanceMeters,
                                 fastestKm: $0.kind == .run ? SplitsCalculator.fastestKmSeconds($0.route) : nil,
                                 hadWalk: $0.walkMeters > 0, isCheckIn: $0.isCheckIn) }
        highlights = WorkoutStore.highlights(for: workout, history: earlier)
    }

    private var savedRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text("Saved").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Theme.paper))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("savedPill")
            if workout.healthKitID != nil {
                Text("Also in Apple Health").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
        }
    }

    @ViewBuilder private var nameView: some View {
        if renaming {
            TextField("Name", text: $draft)
                .font(.system(size: 25, weight: .semibold)).tracking(-0.9)
                .foregroundStyle(Theme.paper)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(commitRename)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.dim, lineWidth: 1))
        } else {
            Text(workout.name)
                .font(.system(size: 25, weight: .semibold)).tracking(-0.9)
                .foregroundStyle(Theme.paper)
                .accessibilityIdentifier("workoutName")
                .contentTransition(.opacity)
                .animation(.easeInOut, value: workout.name)
        }
    }

    private func commitRename() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != workout.name { workout.name = t; workout.userRenamed = true; try? ctx.save() }
        renaming = false
    }

    private var meta: String {
        let kindText: String
        if workout.isCheckIn { kindText = "\(workout.kind.displayName) check-in" }
        else if workout.kind == .run { kindText = workout.walkMeters > 0 ? "Run with walk breaks" : "Run" }
        else { kindText = workout.kind.displayName }
        return [Format.dayLabel(workout.startDate), Format.clockAMPM(workout.startDate), kindText, "iPhone"].joined(separator: " · ")
    }

    private var runWalk: some View {
        VStack(alignment: .leading, spacing: 7) {
            RunWalkBar(segments: workout.segments)
            HStack(spacing: 14) {
                (Text("Ran ") + Text(String(format: "%.2f km", workout.runMeters / 1000)).foregroundStyle(Theme.paper).fontWeight(.semibold))
                if workout.walkMeters > 0 {
                    let n = workout.walkStretches
                    (Text("Walked ") + Text(String(format: "%.2f km", workout.walkMeters / 1000)).foregroundStyle(Theme.paper).fontWeight(.semibold)
                     + Text(" in \(n) stretch\(n == 1 ? "" : "es")"))
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
    }

    private var stats: some View {
        let steps = workout.steps
        let cadenceAvg: String = {
            guard let s = steps, workout.movingSeconds > 30 else { return "--" }
            return String(Int((Double(s) / (workout.movingSeconds / 60)).rounded()))
        }()
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 14) {
            GridRow {
                StatCell(value: Format.km(workout.distanceMeters), unit: "km")
                StatCell(value: Format.duration(workout.movingSeconds), unit: "time")
                StatCell(value: Format.pace(workout.avgPace), unit: "/km avg")
            }
            GridRow {
                StatCell(value: workout.kind == .run ? Format.pace(workout.runningPace) : "-:--",
                         unit: workout.kind == .run ? "/km running" : "/km running")
                StatCell(value: steps.map { $0.formatted() } ?? "--", unit: "steps")
                StatCell(value: cadenceAvg, unit: "steps/min avg")
            }
        }
    }

    private var chips: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(highlights.enumerated()), id: \.offset) { i, h in
                HStack(spacing: 6) {
                    if i == 0 { AccentDot(size: 5) }
                    Text(h.text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.paper)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }

    @ViewBuilder private var splits: some View {
        let s = SplitsCalculator.splits(workout.route)
        if !s.isEmpty {
            let fastest = SplitsCalculator.fastestFullIndex(s)
            VStack(alignment: .leading, spacing: 8) {
                MonoLabel("Splits")
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(s, id: \.index) { sp in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sp.isFull ? "KM \(sp.index)" : String(format: "%.2f KM", sp.meters / 1000))
                                    .font(Theme.label).foregroundStyle(Theme.dim)
                                Text(Format.pace(sp.pace)).font(Theme.number(18)).foregroundStyle(Theme.paper)
                            }
                            .padding(10)
                            .frame(minWidth: 62, alignment: .leading)
                            .background(Theme.surface1)
                            .overlay(alignment: .top) {
                                Rectangle().fill(sp.index == fastest ? Theme.accent : Color.clear).frame(height: 2)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if !workout.isCheckIn {
                Button("Share") { showShare = true }.buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("shareButton")
            }
            Button(renaming ? "Save name" : "Rename") {
                if renaming { commitRename() } else { draft = workout.name; renaming = true; nameFocused = true }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder private var deleteRow: some View {
        if confirmDelete {
            VStack(alignment: .leading, spacing: 10) {
                Text("Delete this workout from Loop? Apple Health keeps its copy.").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                HStack(spacing: 10) {
                    Button("Delete") { ctx.delete(workout); try? ctx.save(); dismiss() }.buttonStyle(PrimaryButtonStyle())
                    Button("Keep") { confirmDelete = false }.buttonStyle(SecondaryButtonStyle())
                }
            }
        } else {
            Button("Delete workout") { confirmDelete = true }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim)
        }
    }
}

/// Non-interactive monochrome map snapshot with the route drawn on top.
struct RouteCard: View {
    let workout: Workout
    @State private var snap: MapSnap?
    @State private var size: CGSize = .zero

    var body: some View {
        let pieces = RoutePieces.bySegments(workout.route, segments: workout.segments)
        GeometryReader { g in
            ZStack {
                Theme.surface1
                if let snap {
                    Image(uiImage: snap.image).resizable().frame(width: g.size.width, height: g.size.height)
                    RouteInk(pieces: RouteInk.projected(pieces, with: snap.project), width: 3)
                } else {
                    RouteInk(pieces: RouteInk.fitted(pieces, in: CGRect(origin: .zero, size: g.size), padding: 24), width: 3)
                }
            }
            .onAppear { size = g.size }
            .onChange(of: g.size) { _, s in size = s }
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityIdentifier("routeCard")
        .task(id: size) {
            guard size.width.isFinite, size.height.isFinite, size.width > 40, size.height > 32 else { return }
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 20, dy: 16)
            snap = await MapSnapshot.make(id: workout.id, route: workout.route, size: size, routeBox: box,
                                          scale: UIScreen.main.scale)
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(width, maxX), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
