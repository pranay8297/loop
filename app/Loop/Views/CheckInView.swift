import SwiftUI
import SwiftData
import CoreLocation

struct CheckInView: View {
    let kind: ActivityKind
    let capability: Capability
    let lastKnown: CLLocation?
    let onDone: (String) -> Void
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @AppStorage("usePlaces") private var usePlaces = true
    @State private var minutes = 45
    @State private var earlier = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Text("Check in").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.paper)
                Spacer()
            }
            .overlay(alignment: .leading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34).background(Circle().fill(Theme.surface1))
                }
            }
            Image(systemName: kind.symbol).font(.system(size: 21)).foregroundStyle(Theme.paper)
                .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface1))
                .padding(.top, 22)
            TitleText(text: kind.checkInTitle).padding(.top, 12)
            why.padding(.top, 8)
            MonoLabel("How long").padding(.top, 24)
            HStack(spacing: 6) {
                ForEach([30, 45, 60, 90], id: \.self) { m in
                    Button("\(m) min") { minutes = m }.buttonStyle(ChipStyle(selected: minutes == m))
                }
            }
            .padding(.top, 8)
            MonoLabel("When").padding(.top, 18)
            HStack(spacing: 6) {
                Button("Just now") { earlier = false }.buttonStyle(ChipStyle(selected: !earlier))
                Button("Earlier today") { earlier = true }.buttonStyle(ChipStyle(selected: earlier))
            }
            .padding(.top, 8)
            Spacer()
            Button("Check in") { save() }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("confirmCheckIn")
        }
        .padding(20)
        .background(Theme.ink)
        .presentationBackground(Theme.ink)
    }

    private var why: some View {
        let (title, detail): (String, String) = {
            if case .cannotTrack(let t, let d, _) = capability { return (t, d) }
            return ("", "Log it without recording.")
        }()
        return (Text(title.isEmpty ? "" : title + ". ").foregroundStyle(Theme.paper).fontWeight(.semibold)
                + Text(detail).foregroundStyle(Theme.dim))
            .font(.system(size: 12.5)).lineSpacing(3)
    }

    private func save() {
        Task {
            _ = await WorkoutStore.checkIn(kind: kind, minutes: minutes, earlier: earlier, in: ctx,
                                           lastKnown: lastKnown, usePlaces: usePlaces)
            withAnimation { onDone("Checked in: \(kind.noun), \(minutes) min. It counts toward your week.") }
            dismiss()
        }
    }
}
