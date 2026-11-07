import AVFoundation
import Observation
import SwiftUI

/// A capture remains an app-private draft until Use is explicitly selected.
@MainActor @Observable final class CaptureReviewSession {
    private(set) var draft: VaultFileDraft?
    private(set) var isSaving = false
    private var generation = 0

    @discardableResult
    func stage(_ captured: VaultFileDraft) -> Bool {
        guard draft == nil, !isSaving else { return false }
        generation += 1
        draft = captured
        return true
    }

    @discardableResult
    func discard() -> Bool {
        guard !isSaving else { return false }
        cancel()
        return true
    }

    func cancel() {
        generation += 1
        draft = nil
    }

    func use(save: (VaultFileDraft) async -> Bool) async -> Bool {
        guard let draft, !isSaving, !Task.isCancelled else { return false }
        let currentGeneration = generation
        isSaving = true
        defer { isSaving = false }
        let saved = await save(draft)
        guard currentGeneration == generation, !Task.isCancelled else { return false }
        if saved { self.draft = nil }
        return saved
    }
}

struct CaptureReviewView: View {
    let draft: VaultFileDraft
    let isSaving: Bool
    let use: () -> Void
    let retake: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(String(localized: "Cancel"), action: cancel)
                    .disabled(isSaving).frame(minHeight: 44)
                Spacer()
                Text(draft.media.kind == .video ? String(localized: "Review video") : String(localized: "Review photo"))
                    .font(.headline)
                Spacer()
                Image(systemName: "lock.fill").frame(width: 44).accessibilityHidden(true)
            }.padding(.horizontal, 20)

            Group {
                if draft.media.kind == .video {
                    CaptureReviewVideo(url: draft.media.url, isSaving: isSaving)
                } else {
                    CaptureReviewPhoto(url: draft.media.url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(String(localized: "Your capture hasn’t been saved yet."))
                .font(.caption).foregroundStyle(.secondary).padding(.top, 16)
            HStack(spacing: 20) {
                Button(String(localized: "Retake"), action: retake)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(.white.opacity(0.12), in: Capsule())
                    .accessibilityIdentifier("retakeCapture")
                Button(String(localized: "Use"), action: use)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(AlbumTheme.accent, in: Capsule())
                    .accessibilityIdentifier("useCapture")
            }
            .font(.headline).disabled(isSaving)
            .padding(20)
        }
        .foregroundStyle(.white).background(.black).preferredColorScheme(.dark)
        .accessibilityIdentifier("captureReview")
        .overlay {
            if isSaving {
                ProgressView(String(localized: "Saving changes…"))
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

private struct CaptureReviewPhoto: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if failed {
                    ContentUnavailableView(String(localized: "Photo unavailable"), systemImage: "photo",
                                           description: Text(String(localized: "This file could not be opened.")))
                } else { ProgressView() }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: url) {
            // A short-lived loader keeps discarded captures out of the library's image cache.
            let loaded = await ImageLoader().image(at: url, maxPixels: 3000)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

/// Inline playback avoids a second fullscreen presentation during capture review.
/// The player never enables external playback or Picture in Picture.
private struct CaptureReviewVideo: View {
    let url: URL
    let isSaving: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var resumeAfterScrubbing = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            if let player {
                CaptureVideoSurface(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let seconds = player.currentTime().seconds
                    let position = seconds.isFinite ? min(duration, max(0, seconds)) : 0
                    HStack(spacing: 12) {
                        Button {
                            if player.rate > 0 { player.pause() }
                            else {
                                if position >= duration - 0.1 { player.seek(to: .zero) }
                                player.play()
                            }
                        } label: {
                            Image(systemName: player.rate > 0 ? "pause.fill" : "play.fill")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(player.rate > 0 ? String(localized: "Pause video") : String(localized: "Play video"))
                        Slider(value: Binding(get: { isScrubbing ? scrubPosition : position }, set: { scrubPosition = $0 }),
                               in: 0...max(duration, 0.01)) { editing in
                            if editing {
                                scrubPosition = position
                                resumeAfterScrubbing = player.rate > 0
                                player.pause()
                            } else {
                                player.seek(to: CMTime(seconds: scrubPosition, preferredTimescale: 600))
                                if resumeAfterScrubbing && !isSaving && scenePhase == .active { player.play() }
                                resumeAfterScrubbing = false
                            }
                            isScrubbing = editing
                        }
                        .accessibilityLabel(String(localized: "Video position"))
                        Text(verbatim: timestamp(isScrubbing ? scrubPosition : position) + " / " + timestamp(duration))
                            .font(.caption.monospacedDigit()).fixedSize()
                    }
                    .disabled(isSaving).padding(.horizontal, 16)
                }
            } else if failed {
                ContentUnavailableView(String(localized: "This file could not be opened."), systemImage: "video")
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: url) {
            do {
                let asset = AVURLAsset(url: url)
                let (playable, length) = try await asset.load(.isPlayable, .duration)
                guard !Task.isCancelled else { return }
                guard playable, length.seconds.isFinite, length.seconds > 0 else { failed = true; return }
                duration = length.seconds
                let playback = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                playback.allowsExternalPlayback = false
                player = playback
            } catch { if !Task.isCancelled { failed = true } }
        }
        .onChange(of: isSaving) { _, saving in if saving { pause() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { pause() } }
        .onDisappear { pause(); player?.replaceCurrentItem(with: nil); player = nil }
    }

    private func pause() { player?.pause(); resumeAfterScrubbing = false }
    private func timestamp(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CaptureVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> CaptureVideoView {
        let view = CaptureVideoView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ view: CaptureVideoView, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: CaptureVideoView, coordinator: ()) { view.playerLayer.player = nil }
}

private final class CaptureVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
