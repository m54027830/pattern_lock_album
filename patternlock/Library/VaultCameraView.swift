import ARKit
import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum VaultCameraMode: CaseIterable, Identifiable {
    case photo, video, silentPhoto
    var id: Self { self }
    var title: String {
        switch self {
        case .photo: String(localized: "Photo")
        case .video: String(localized: "Video")
        case .silentPhoto: String(localized: "Silent photo")
        }
    }
}

struct VaultCameraView: View {
    let store: LibraryStore
    let folderID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var mode = VaultCameraMode.photo
    @State private var authorizedMode: VaultCameraMode?
    @State private var permissionMessage: String?
    @State private var error: String?
    @State private var draft: VaultFileDraft?
    @State private var saving = false
    @State private var preparingCapture = false
    @State private var closed = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(String(localized: "Cancel")) { close() }.disabled(saving)
                Spacer()
                Text(String(localized: "Camera")).font(.headline)
                Spacer()
                Image(systemName: "lock.fill").accessibilityHidden(true)
            }.padding()
            Text(String(localized: "Saved only to this vault, never to Photos."))
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            Picker(String(localized: "Camera mode"), selection: $mode) {
                ForEach(VaultCameraMode.allCases) { choice in Text(choice.title).tag(choice) }
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 12)
            .disabled(draft != nil || saving || preparingCapture)

            Group {
                if saving {
                    ProgressView(String(localized: "Saving changes…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if draft != nil {
                    VStack(spacing: 20) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text(String(localized: "Your capture hasn’t been saved yet."))
                        Button(String(localized: "Try again")) { saveDraft() }.buttonStyle(.borderedProminent)
                        Button(String(localized: "Discard"), role: .destructive) { draft = nil }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                } else if let permissionMessage {
                    ContentUnavailableView {
                        Label(String(localized: "Camera unavailable"), systemImage: "camera")
                    } description: {
                        Text(permissionMessage)
                    } actions: {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button(String(localized: "Open Settings")) { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                        }
                    }
                } else if authorizedMode == mode && !closed {
                    if mode == .silentPhoto {
                        SilentVaultCamera(captured: accept, failed: { error = $0 })
                    } else {
                        VaultSystemCamera(video: mode == .video, captured: accept, cancelled: close, failed: { error = $0 }, preparing: { preparingCapture = $0 })
                            .id(mode)
                            .disabled(preparingCapture)
                            .overlay { if preparingCapture { ProgressView(String(localized: "Saving changes…")).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .background(.black).preferredColorScheme(.dark)
        .task(id: mode) { await authorize() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { close() } }
        .onDisappear { closed = true; saveTask?.cancel(); draft = nil }
        .alert(String(localized: "Something went wrong"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func authorize() async {
        authorizedMode = nil
        permissionMessage = nil
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            permissionMessage = String(localized: "Use a device with a camera to take photos and videos.")
            return
        }
        if mode == .silentPhoto, !ARWorldTrackingConfiguration.isSupported {
            permissionMessage = String(localized: "Silent photos aren’t supported on this device. Use Photo or Video instead.")
            return
        }
        let camera = await permission(for: .video)
        guard !Task.isCancelled, !closed else { return }
        guard camera else {
            permissionMessage = String(localized: "Allow camera access in Settings to capture directly into your vault.")
            return
        }
        if mode == .video {
            let microphone = await permission(for: .audio)
            guard !Task.isCancelled, !closed else { return }
            guard microphone else {
                permissionMessage = String(localized: "Allow microphone access in Settings to record videos with sound.")
                return
            }
        }
        authorizedMode = mode
    }

    private func permission(for media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: media)
        default: false
        }
    }

    private func accept(_ captured: VaultFileDraft) {
        guard !closed, !saving, draft == nil else { return }
        draft = captured
        saveDraft()
    }

    private func saveDraft() {
        guard let draft, !saving, !closed else { return }
        saving = true
        saveTask = Task {
            let success = await store.saveCapture(draft, into: folderID)
            guard !closed, !Task.isCancelled else { return }
            saving = false
            if success { self.draft = nil; close() }
            else {
                error = store.errorMessage ?? String(localized: "This file could not be opened.")
                store.errorMessage = nil
            }
        }
    }

    private func close() {
        closed = true
        saveTask?.cancel()
        draft = nil
        dismiss()
    }
}

/// UIImagePickerController returns an app-local capture. No Photos write APIs are used.
private struct VaultSystemCamera: UIViewControllerRepresentable {
    let video: Bool
    let captured: (VaultFileDraft) -> Void
    let cancelled: () -> Void
    let failed: (String) -> Void
    let preparing: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [video ? UTType.movie.identifier : UTType.image.identifier]
        picker.cameraCaptureMode = video ? .video : .photo
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    static func dismantleUIViewController(_ picker: UIImagePickerController, coordinator: Coordinator) {
        coordinator.active = false
        coordinator.staging?.cancel()
        picker.delegate = nil
        if picker.cameraCaptureMode == .video { picker.stopVideoCapture() }
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VaultSystemCamera
        var active = true
        var staging: Task<Void, Never>?
        init(parent: VaultSystemCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.cancelled() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard active else { return }
            if let movie = info[.mediaURL] as? URL {
                parent.preparing(true)
                staging = Task {
                    do {
                        let draft = try await CameraDraftWriter.shared.copyMovie(movie)
                        guard active, !Task.isCancelled else { return }
                        parent.preparing(false)
                        parent.captured(draft)
                    } catch {
                        guard active, !Task.isCancelled else { return }
                        parent.preparing(false)
                        parent.failed(error.localizedDescription)
                    }
                }
                return
            }
            do {
                let draft: VaultFileDraft
                if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) {
                    draft = try VaultFileDraft.write(data, name: "Photo-\(UUID().uuidString.prefix(8)).jpg", kind: .photo)
                } else { throw LibraryError.unsupportedMedia }
                parent.captured(draft)
            } catch { parent.failed(error.localizedDescription) }
        }
    }
}

private actor CameraDraftWriter {
    static let shared = CameraDraftWriter()
    func copyMovie(_ url: URL) throws -> VaultFileDraft {
        // Large recordings are copied off the main actor before the picker is dismissed.
        defer { try? FileManager.default.removeItem(at: url) }
        try Task.checkCancellation()
        let draft = try VaultFileDraft.copy(url, kind: .video)
        try Task.checkCancellation()
        return draft
    }
}

private struct SilentVaultCamera: View {
    let captured: (VaultFileDraft) -> Void
    let failed: (String) -> Void
    @State private var controller = SilentCameraController()

    var body: some View {
        VStack(spacing: 16) {
            SilentCameraPreview(controller: controller)
                .overlay { if !controller.ready { ProgressView() } }
            Text(String(localized: "Silent photos use the rear camera’s video frame and may have less detail."))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button {
                do { captured(try controller.capture()) }
                catch { failed(error.localizedDescription) }
            } label: {
                Circle().fill(.white).frame(width: 64, height: 64)
                    .padding(5).overlay { Circle().stroke(.white, lineWidth: 3) }
            }
            .disabled(!controller.ready)
            .accessibilityLabel(String(localized: "Take silent photo"))
            .padding(.bottom, 20)
        }
        .onChange(of: controller.error) { _, error in if let error { failed(error) } }
    }
}

@MainActor @Observable private final class SilentCameraController: NSObject, ARSessionDelegate {
    let session = ARSession()
    var ready = false
    var error: String?
    weak var view: ARSCNView?
    private var active = false

    func start(in view: ARSCNView) {
        self.view = view
        active = true
        session.delegate = self
        session.delegateQueue = .main
        let config = ARWorldTrackingConfiguration()
        config.isAutoFocusEnabled = true
        session.run(config)
    }

    func stop() {
        active = false
        ready = false
        session.pause()
        session.delegate = nil
        view = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) { if active { ready = true } }
    func session(_ session: ARSession, didFailWithError error: Error) { ready = false; self.error = error.localizedDescription }
    func sessionWasInterrupted(_ session: ARSession) { ready = false }
    func sessionInterruptionEnded(_ session: ARSession) {
        guard active else { return }
        session.run(ARWorldTrackingConfiguration(), options: [.resetTracking])
    }

    func capture() throws -> VaultFileDraft {
        guard active, ready, let frame = session.currentFrame else { throw LibraryError.unsupportedMedia }
        // Encode only the camera frame: no scene overlays or tracking data are saved.
        let orientation = view?.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        let exif: CGImagePropertyOrientation
        switch orientation {
        case .landscapeLeft: exif = .up
        case .landscapeRight: exif = .down
        case .portraitUpsideDown: exif = .left
        default: exif = .right
        }
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(exif)
        guard let data = CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else {
            throw LibraryError.unsupportedMedia
        }
        return try VaultFileDraft.write(data, name: "Photo-\(UUID().uuidString.prefix(8)).jpg", kind: .photo)
    }
}

private struct SilentCameraPreview: UIViewRepresentable {
    let controller: SilentCameraController
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = controller.session
        controller.start(in: view)
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
    func makeCoordinator() -> SilentCameraController { controller }
    static func dismantleUIView(_ view: ARSCNView, coordinator: SilentCameraController) { coordinator.stop() }
}
