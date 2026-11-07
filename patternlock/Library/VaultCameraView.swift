import ARKit
import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum VaultCameraMode: CaseIterable, Identifiable {
    case photo, video
    var id: Self { self }
    var title: String {
        switch self {
        case .photo: String(localized: "Photo")
        case .video: String(localized: "Video")
        }
    }
}

private struct VaultCameraScene: Hashable {
    var mode = VaultCameraMode.photo
    var muted = false
    var front = false
    var usesSilentCamera: Bool { mode == .photo && muted }
    var device: UIImagePickerController.CameraDevice { front ? .front : .rear }
    var supportsSilentCapture: Bool {
        front ? ARFaceTrackingConfiguration.isSupported : ARWorldTrackingConfiguration.isSupported
    }
}

struct VaultCameraView: View {
    let store: LibraryStore
    let folderID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var cameraScene = VaultCameraScene()
    @State private var authorizedScene: VaultCameraScene?
    @State private var systemCamera = VaultSystemCameraController()
    @State private var silentCamera = SilentCameraController()
    @State private var permissionMessage: String?
    @State private var error: String?
    @State private var draft: VaultFileDraft?
    @State private var saving = false
    @State private var preparingCapture = false
    @State private var closed = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if showsCameraPreview {
                VaultCameraSurface(isVideo: cameraScene.mode == .video) {
                    cameraPreview
                } header: {
                    cameraHeader
                } controls: {
                    captureControls.background(.black.opacity(0.9))
                }
            } else {
                VStack(spacing: 0) {
                    cameraHeader
                    captureStatus
                }
            }
        }
        .background(.black).preferredColorScheme(.dark)
        .task(id: cameraScene) { await authorize() }
        .onChange(of: silentCamera.error) { _, message in if let message { error = message } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { close() } }
        .onDisappear { closed = true; stopCameras(); saveTask?.cancel(); draft = nil }
        .alert(String(localized: "Something went wrong"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(String(localized: "OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var cameraHeader: some View {
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
            Picker(String(localized: "Camera mode"), selection: Binding(get: { cameraScene.mode }, set: { mode in reloadCamera { $0.mode = mode } })) {
                ForEach(VaultCameraMode.allCases) { choice in Text(choice.title).tag(choice) }
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 12)
            .disabled(cameraControlsLocked)
        }
        .background(.black.opacity(0.9))
    }

    @ViewBuilder private var captureStatus: some View {
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
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var showsCameraPreview: Bool {
        authorizedScene == cameraScene && !closed && !saving && draft == nil && permissionMessage == nil
    }

    @ViewBuilder private var cameraPreview: some View {
        if showsCameraPreview {
            Group {
                if cameraScene.usesSilentCamera {
                    SilentCameraPreview(controller: silentCamera, front: cameraScene.front)
                        .overlay { if !silentCamera.ready { ProgressView() } }
                } else {
                    VaultSystemCamera(scene: cameraScene, controller: systemCamera, captured: accept, cancelled: close,
                                      failed: { error = $0 }, preparing: { preparingCapture = $0 })
                        .allowsHitTesting(!preparingCapture)
                        .overlay { if preparingCapture { ProgressView(String(localized: "Saving changes…")) } }
                }
            }
            .id(cameraScene)
        } else { Color.black }
    }

    private var cameraControlsLocked: Bool { draft != nil || saving || preparingCapture || systemCamera.isCapturing }

    private var captureControls: some View {
        VStack(spacing: 8) {
            if let started = systemCamera.recordingStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    Text(verbatim: String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.caption.monospacedDigit()).foregroundStyle(.red)
                }
            }
            HStack(spacing: 0) {
                // Equal side columns keep the shutter centered, including on small phones.
                Color.clear.frame(width: 96, height: 44).accessibilityHidden(true)
                Spacer(minLength: 0)
                Button(action: capture) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 72, height: 72)
                        if systemCamera.isRecording {
                            RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(cameraScene.mode == .video ? .red : .white).frame(width: 60, height: 60)
                        }
                    }
                }
                .disabled(preparingCapture || (cameraScene.usesSilentCamera ? !silentCamera.ready : !systemCamera.canCapture))
                .accessibilityLabel(cameraScene.mode == .photo ? String(localized: "Take photo") : (systemCamera.isRecording ? String(localized: "Stop recording") : String(localized: "Record video")))
                .accessibilityIdentifier("cameraShutter")
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if cameraScene.mode == .photo {
                        Button { reloadCamera { $0.muted.toggle() } } label: {
                            Image(systemName: cameraScene.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 18)).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(String(localized: "Shutter sound"))
                        .accessibilityValue(cameraScene.muted ? String(localized: "Off") : String(localized: "On"))
                        .accessibilityIdentifier("toggleShutterSound")
                        .disabled(cameraControlsLocked || !cameraScene.supportsSilentCapture)
                    } else { Color.clear.frame(width: 44, height: 44).accessibilityHidden(true) }
                    Button { reloadCamera { $0.front.toggle() } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 20)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(cameraScene.front ? String(localized: "Use rear camera") : String(localized: "Use front camera"))
                    .accessibilityIdentifier("switchCamera")
                    .disabled(cameraControlsLocked || !canSwitchCamera)
                }.foregroundStyle(.white)
            }
        }.padding(.horizontal, 12).padding(.vertical, 18)
    }

    private var canSwitchCamera: Bool {
        var other = cameraScene
        other.front.toggle()
        let captureMode = other.mode == .video ? UIImagePickerController.CameraCaptureMode.video : .photo
        return UIImagePickerController.isCameraDeviceAvailable(other.device)
            && (UIImagePickerController.availableCaptureModes(for: other.device)?.contains(NSNumber(value: captureMode.rawValue)) == true)
            && (!other.usesSilentCamera || other.supportsSilentCapture)
    }

    private func reloadCamera(_ update: (inout VaultCameraScene) -> Void) {
        guard !cameraControlsLocked else { return }
        // Stop the previous camera before mounting the replacement. Each scene owns
        // fresh controllers so a late dismantle/callback cannot stop the new session.
        stopCameras()
        authorizedScene = nil
        systemCamera = VaultSystemCameraController()
        silentCamera = SilentCameraController()
        update(&cameraScene)
        if !cameraScene.supportsSilentCapture { cameraScene.muted = false }
    }

    private func stopCameras() { systemCamera.stop(); silentCamera.stop() }

    private func capture() {
        if cameraScene.usesSilentCamera {
            do { accept(try silentCamera.capture()) }
            catch { self.error = error.localizedDescription }
        } else if !systemCamera.capture() {
            error = String(localized: "Couldn’t start recording. Try again after checking available storage.")
        }
    }

    private func authorize() async {
        let requestedScene = cameraScene
        authorizedScene = nil
        permissionMessage = nil
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            permissionMessage = String(localized: "Use a device with a camera to take photos and videos.")
            return
        }
        if requestedScene.usesSilentCamera, !requestedScene.supportsSilentCapture {
            permissionMessage = String(localized: "Silent photos aren’t supported on this device. Use Photo or Video instead.")
            return
        }
        let camera = await permission(for: .video)
        guard !Task.isCancelled, !closed, requestedScene == cameraScene else { return }
        guard camera else {
            permissionMessage = String(localized: "Allow camera access in Settings to capture directly into your vault.")
            return
        }
        if requestedScene.mode == .video {
            let microphone = await permission(for: .audio)
            guard !Task.isCancelled, !closed, requestedScene == cameraScene else { return }
            guard microphone else {
                permissionMessage = String(localized: "Allow microphone access in Settings to record videos with sound.")
                return
            }
        }
        authorizedScene = requestedScene
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
        stopCameras()
        saveTask?.cancel()
        draft = nil
        dismiss()
    }
}

/// Video keeps its full-screen picker to avoid a black strip. Photo previews sit
/// between the header and shutter row, so those controls cannot obscure the
/// top and bottom of the normal photo frame and make it appear square.
struct VaultCameraSurface<Preview: View, Header: View, Controls: View>: View {
    let isVideo: Bool
    @ViewBuilder let preview: Preview
    @ViewBuilder let header: Header
    @ViewBuilder let controls: Controls

    var body: some View {
        ZStack {
            if isVideo {
                GeometryReader { geometry in
                    preview
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                header
                if isVideo {
                    Spacer(minLength: 0)
                } else {
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                controls
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// UIImagePickerController returns an app-local capture. No Photos write APIs are used.
private struct VaultSystemCamera: UIViewControllerRepresentable {
    let scene: VaultCameraScene
    let controller: VaultSystemCameraController
    let captured: (VaultFileDraft) -> Void
    let cancelled: () -> Void
    let failed: (String) -> Void
    let preparing: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> VaultCameraHost {
        let host = VaultCameraHost()
        let picker = host.picker
        picker.sourceType = .camera
        picker.mediaTypes = [scene.mode == .video ? UTType.movie.identifier : UTType.image.identifier]
        picker.cameraDevice = scene.device
        picker.cameraCaptureMode = scene.mode == .video ? .video : .photo
        // A shared control row keeps the sound toggle beside the lens switch
        // in both the standard and AR previews, using only public UIKit APIs.
        picker.showsCameraControls = false
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        controller.attach(picker)
        host.onReady = { [weak controller] in controller?.becameReady() }
        return host
    }
    func updateUIViewController(_ host: VaultCameraHost, context: Context) {}
    static func dismantleUIViewController(_ host: VaultCameraHost, coordinator: Coordinator) {
        coordinator.active = false
        coordinator.staging?.cancel()
        host.onReady = nil
        host.picker.delegate = nil
        coordinator.parent.controller.stop()
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VaultSystemCamera
        var active = true
        var staging: Task<Void, Never>?
        init(parent: VaultSystemCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.cancelled() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard active, parent.controller.isCapturing else { return }
            parent.controller.finishedCapture()
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

/// Observe appearance through a container, without subclassing or inspecting
/// UIImagePickerController's private view hierarchy.
private final class VaultCameraHost: UIViewController {
    let picker = UIImagePickerController()
    var onReady: (() -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(picker)
        picker.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker.view)
        NSLayoutConstraint.activate([
            picker.view.topAnchor.constraint(equalTo: view.topAnchor),
            picker.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            picker.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        picker.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onReady?()
    }
}

@MainActor @Observable final class VaultSystemCameraController {
    @ObservationIgnored private weak var picker: UIImagePickerController?
    private var ready = false
    private(set) var isCapturing = false
    private(set) var recordingStartedAt: Date?
    var isRecording: Bool { recordingStartedAt != nil }
    var canCapture: Bool { ready && (!isCapturing || isRecording) }

    func attach(_ picker: UIImagePickerController) { self.picker = picker }
    func becameReady() { ready = picker != nil }

    @discardableResult
    func capture() -> Bool {
        guard let picker, canCapture else { return false }
        if isRecording {
            recordingStartedAt = nil
            picker.stopVideoCapture()
            // Keep the other controls locked until the delegate delivers the movie.
            return true
        }
        isCapturing = true
        if picker.cameraCaptureMode == .video {
            guard picker.startVideoCapture() else { isCapturing = false; return false }
            recordingStartedAt = Date()
        } else { picker.takePicture() }
        return true
    }

    func finishedCapture() { isCapturing = false; recordingStartedAt = nil }

    func stop() {
        ready = false
        picker?.delegate = nil
        if isRecording { picker?.stopVideoCapture() }
        finishedCapture()
        picker = nil
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

@MainActor @Observable private final class SilentCameraController: NSObject, ARSessionDelegate {
    let session = ARSession()
    var ready = false
    var error: String?
    weak var view: ARSCNView?
    private var active = false
    private var configuration: ARConfiguration?

    func start(in view: ARSCNView, front: Bool) {
        self.view = view
        active = true
        session.delegate = self
        session.delegateQueue = .main
        let config: ARConfiguration
        if front { config = ARFaceTrackingConfiguration() }
        else {
            let rear = ARWorldTrackingConfiguration()
            rear.isAutoFocusEnabled = true
            config = rear
        }
        // Only capturedImage is saved; no face anchors or tracking data leave this session.
        configuration = config
        session.run(config)
    }

    func stop() {
        active = false
        ready = false
        session.pause()
        session.delegate = nil
        configuration = nil
        view = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) { if active { ready = true } }
    func session(_ session: ARSession, didFailWithError error: Error) { ready = false; self.error = error.localizedDescription }
    func sessionWasInterrupted(_ session: ARSession) { ready = false }
    func sessionInterruptionEnded(_ session: ARSession) {
        guard active, let configuration else { return }
        session.run(configuration, options: [.resetTracking])
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
    let front: Bool
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = controller.session
        controller.start(in: view, front: front)
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
    func makeCoordinator() -> SilentCameraController { controller }
    static func dismantleUIView(_ view: ARSCNView, coordinator: SilentCameraController) { coordinator.stop() }
}
