import SwiftUI
import SwiftData
import Photos
import PhotosUI

/// Direct Instagram Stories sharing needs a Facebook App ID. Empty keeps the button hidden;
/// the system share sheet still lists Instagram.
enum InstagramConfig {
    static let facebookAppID = ""
}

struct ShareScreen: View {
    let workout: Workout
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @AppStorage("shareStyle") private var styleRaw = CardStyle.city.rawValue
    @AppStorage("shareHideEnds") private var hide = true
    @State private var data: CardData?
    @State private var snaps: [CardStyle: MapSnap] = [:]
    @State private var photo: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var shareImage: ShareImage?
    @State private var toast: String?
    @State private var busy = false

    private var style: CardStyle { CardStyle(rawValue: styleRaw) ?? .city }
    private var styleBinding: Binding<CardStyle> { Binding(get: { style }, set: { styleRaw = $0.rawValue }) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let data {
                TabView(selection: styleBinding) {
                    ForEach(CardStyle.allCases) { s in
                        preview(s, data).tag(s).padding(.horizontal, 28)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            controls
        }
        .background(Theme.ink.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let toast {
                Toast(text: toast).padding(.bottom, 90)
                    .accessibilityIdentifier("shareToast")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .presentationBackground(Theme.ink)
        .sheet(item: $shareImage) { item in ActivityView(items: [item.image]).ignoresSafeArea() }
        .task { await load() }
        .onChange(of: pickerItem) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) { photo = img }
            }
        }
    }

    private func load() async {
        let history = CardRenderer.history(in: ctx)
        let d = CardData(workout: workout, history: history)
        data = d
        for s in [CardStyle.city, .photo] {
            if let snap = await CardRenderer.snapshot(for: d, style: s) { snaps[s] = snap }
        }
    }

    private var header: some View {
        ZStack {
            Text("Share").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.paper)
                .accessibilityIdentifier("shareScreen")
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.paper)
                        .frame(width: 32, height: 32).background(Circle().fill(Theme.surface2))
                }
                .accessibilityLabel("Close").accessibilityIdentifier("closeShare")
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private func preview(_ s: CardStyle, _ d: CardData) -> some View {
        GeometryReader { g in
            let k = min(g.size.width / CardText.cardSize.width, g.size.height / CardText.cardSize.height)
            ShareCard(style: s, data: d, hide: hide, snap: snaps[s], photo: s == .photo ? photo : nil)
                .clipShape(RoundedRectangle(cornerRadius: 14 / max(k, 0.01)))
                .scaleEffect(k, anchor: .topLeading)
                .frame(width: CardText.cardSize.width * k, height: CardText.cardSize.height * k, alignment: .topLeading)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement().accessibilityIdentifier("cardPreview-\(s.rawValue)")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(CardStyle.allCases) { s in
                            Button(s.title) { withAnimation(.easeInOut(duration: 0.25)) { styleRaw = s.rawValue } }
                                .buttonStyle(ChipStyle(selected: s == style))
                                .accessibilityIdentifier("style-\(s.rawValue)")
                                .id(s)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
                .onChange(of: styleRaw) { _, _ in withAnimation { proxy.scrollTo(style, anchor: .center) } }
            }
            .padding(.horizontal, -20)
            if style.usesRoute {
                Toggle(isOn: $hide) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide start and finish").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.paper)
                        Text("First and last 200 m stay off the card").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("hideEndsToggle")
            }
            if style == .photo {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(photo == nil ? "Choose photo" : "Change photo", systemImage: "photo")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.paper)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .accessibilityIdentifier("choosePhoto")
            }
            HStack(spacing: 10) {
                Button("Share") { Task { await share() } }.buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("shareCardButton")
                Button("Save") { Task { await save() } }.buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("saveCardButton")
            }
            .disabled(busy || data == nil)
            if !InstagramConfig.facebookAppID.isEmpty, canOpenInstagram {
                Button("Instagram Stories") { Task { await shareToStories() } }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
    }

    private func image() async -> UIImage? {
        guard let data else { return nil }
        var snap = snaps[style]
        if style == .city || (style == .photo && photo == nil), snap == nil {
            snap = await CardRenderer.snapshot(for: data, style: style, timeout: 4)
        }
        return CardRenderer.render(style, data: data, hide: hide, snap: snap, photo: style == .photo ? photo : nil)
    }

    private func share() async {
        busy = true; defer { busy = false }
        guard let img = await image() else { return show("Could not make the card.") }
        shareImage = ShareImage(image: img)
    }

    private func save() async {
        busy = true; defer { busy = false }
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else { return show("Allow Photos access in Settings to save cards.") }
        guard let img = await image(), let png = img.pngData() else { return show("Could not make the card.") }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
            }
            show("Saved to Photos")
        } catch {
            show("Could not save to Photos.")
        }
    }

    private var canOpenInstagram: Bool {
        URL(string: "instagram-stories://share").map { UIApplication.shared.canOpenURL($0) } ?? false
    }

    private func shareToStories() async {
        guard let img = await image(), let png = img.pngData(),
              let url = URL(string: "instagram-stories://share?source_application=\(InstagramConfig.facebookAppID)") else { return }
        UIPasteboard.general.setItems([["com.instagram.sharedSticker.backgroundImage": png]],
                                      options: [.expirationDate: Date().addingTimeInterval(300)])
        await UIApplication.shared.open(url)
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation { if toast == text { toast = nil } }
        }
    }
}

struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
