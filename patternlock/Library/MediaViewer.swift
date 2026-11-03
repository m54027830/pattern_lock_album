import AVKit
import SwiftUI

struct MediaViewer: View {
    let items: [MediaItem]
    let initialID: UUID
    @Bindable var store: LibraryStore
    @State private var currentID: UUID
    @Environment(\.dismiss) private var dismiss

    init(items: [MediaItem], initialID: UUID, store: LibraryStore) {
        self.items = items
        self.initialID = initialID
        self.store = store
        _currentID = State(initialValue: initialID)
    }

    private var currentItem: MediaItem? { items.first { $0.id == currentID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.medium)).frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle()) }
                    .accessibilityLabel(String(localized: "Close preview"))
                Spacer()
                Text(String(localized: "\((items.firstIndex { $0.id == currentID } ?? 0) + 1) of \(items.count)")).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button { Task { await store.export([currentID]) } } label: {
                    Image(systemName: "square.and.arrow.up").font(.body).frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle())
                }.accessibilityLabel(String(localized: "Export media")).disabled(store.isBusy)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            TabView(selection: $currentID) {
                ForEach(items) { item in
                    MediaPage(item: item, url: store.repository.mediaURL(item), isActive: item.id == currentID).tag(item.id)
                }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            if let item = currentItem {
                VStack(spacing: 6) {
                    Text(item.originalName).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(String(localized: "Added \(item.importedAt.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }.padding(22)
            }
        }
        .background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .statusBarHidden()
        .sheet(item: $store.exportSession, onDismiss: { store.finishExport() }) { session in
            ShareSheet(urls: session.urls) { store.finishExport() }
        }
        .overlay { if store.isBusy { ProgressView(String(localized: "Preparing export…")).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .alert(String(localized: "Couldn’t export"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

private struct MediaPage: View {
    let item: MediaItem
    let url: URL
    let isActive: Bool
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var failed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if item.kind == .video {
                if let player { VideoPlayer(player: player) }
                else { ProgressView().tint(.white) }
            } else if let image {
                ZoomablePhoto(image: image)
            } else if failed {
                ContentUnavailableView(String(localized: "Photo unavailable"), systemImage: "photo", description: Text(String(localized: "This file could not be opened.")))
            } else { ProgressView().tint(.white) }
        }
        .task(id: item.id) {
            if item.kind == .video { player = AVPlayer(url: url) }
            else { image = await ImageLoader.shared.image(at: url, maxPixels: 3000); failed = image == nil }
        }
        .onChange(of: isActive) { _, active in if !active { player?.pause() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
        .onDisappear { player?.pause() }
    }
}

private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PhotoScrollView {
        let scroll = PhotoScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.imageView.image = image
        scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }
    func updateUIView(_ scroll: PhotoScrollView, context: Context) { scroll.imageView.image = image }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.imageView }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? PhotoScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: scroll.imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

private final class PhotoScrollView: UIScrollView {
    let imageView = UIImageView()
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize {
            zoomScale = 1
            previousSize = bounds.size
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }
}
