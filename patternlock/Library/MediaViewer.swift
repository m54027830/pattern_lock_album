import AVKit
import QuickLook
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
                if store.allowsExport { Button { Task { await store.export([currentID]) } } label: {
                    Image(systemName: "square.and.arrow.up").font(.body).frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle())
                }.accessibilityLabel(String(localized: "Export media")).disabled(store.isBusy) }
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
            if item.kind == .memo {
                MemoPreview(url: url)
            } else if item.kind == .document {
                VaultDocumentPreview(url: url, name: item.originalName)
            } else if item.kind == .video {
                if let player { FullscreenVideoPlayer(player: player) }
                else { ProgressView().tint(.white) }
            } else if let image {
                ZoomablePhoto(image: image)
            } else if failed {
                ContentUnavailableView(String(localized: "Photo unavailable"), systemImage: "photo", description: Text(String(localized: "This file could not be opened.")))
            } else { ProgressView().tint(.white) }
        }
        .task(id: item.id) {
            if item.kind == .video {
                // Returning from native fullscreen can restart this task.
                // Keep the same player so its position is preserved.
                if player == nil { player = AVPlayer(url: url); player?.allowsExternalPlayback = false }
            }
            else if item.kind == .photo { image = await ImageLoader.shared.image(at: url, maxPixels: 3000); failed = image == nil }
        }
        .onChange(of: isActive) { _, active in if !active { player?.pause() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
    }
}

private actor MemoReader {
    static let shared = MemoReader()
    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
}

private struct MemoPreview: View {
    let url: URL
    @State private var text: String?
    @State private var failed = false
    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Text(verbatim: text).font(.body).lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            } else if failed {
                ContentUnavailableView(String(localized: "This file could not be opened."), systemImage: "note.text")
            } else { ProgressView() }
        }
        .task(id: url) {
            do { text = try await MemoReader.shared.read(url) }
            catch { failed = true }
        }
    }
}

/// Embed only Quick Look's content, without its navigation/share toolbar. Export stays
/// in MediaViewer, where the vault's sharing policy is enforced for every item kind.
private struct VaultDocumentPreview: UIViewControllerRepresentable {
    let url: URL
    let name: String
    func makeCoordinator() -> Coordinator { Coordinator(url: url, name: name) }
    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        container.addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            preview.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor)
        ])
        preview.didMove(toParent: container)
        return container
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, name: String) { previewItemURL = url; previewItemTitle = name }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { self }
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
        func previewController(_ controller: QLPreviewController, shouldOpen url: URL, for item: any QLPreviewItem) -> Bool { false }
    }
}

private struct FullscreenVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        // Vault media must stay inside the app's lock and privacy cover.
        controller.allowsPictureInPicturePlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        // Native fullscreen covers MediaPage without ending playback. Stop only
        // when its controller is removed; page changes/backgrounding pause above.
        controller.player?.pause()
        controller.player = nil
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
