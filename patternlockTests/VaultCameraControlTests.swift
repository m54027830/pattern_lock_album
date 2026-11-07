import UIKit
import SwiftUI
import XCTest
@testable import patternlock

@MainActor final class VaultCameraControlTests: XCTestCase {
    func testCameraPreviewFillsWindowAcrossModesRotationAndRecordingControls() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let initialPreview = CameraPreviewProbeState()
        let host = UIHostingController(rootView: surface(preview: initialPreview, video: false, recording: false))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393), CGSize(width: 393, height: 852)] {
            window.frame = CGRect(origin: .zero, size: size)
            // Include the side insets that a camera encounters in landscape.
            host.additionalSafeAreaInsets = size.width > size.height ? UIEdgeInsets(top: 0, left: 59, bottom: 0, right: 59) : .zero
            for (video, recording) in [(false, false), (true, false), (true, true), (false, false)] {
                let state = CameraPreviewProbeState()
                host.rootView = surface(preview: state, video: video, recording: recording)
                for _ in 0..<3 {
                    window.setNeedsLayout()
                    window.layoutIfNeeded()
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    await Task.yield()
                }
                let preview = try XCTUnwrap(state.view)
                XCTAssertNotNil(preview.window)
                let frame = preview.convert(preview.bounds, to: window)
                XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
                XCTAssertEqual(frame.maxX, window.bounds.width, accuracy: 0.5, "No uncovered strip after changing to video")
                XCTAssertEqual(frame.minY, 0, accuracy: 0.5)
                XCTAssertEqual(frame.height, window.bounds.height, accuracy: 0.5, "Controls must overlay the picker, not shrink it")
            }
        }
    }

    private func surface(preview: CameraPreviewProbeState, video: Bool, recording: Bool) -> some View {
        VaultCameraSurface {
            CameraPreviewProbe(state: preview, video: video).id(video)
        } controls: {
            VStack(spacing: 0) {
                Color.black.frame(height: 140)
                Spacer(minLength: 0)
                Color.black.frame(height: recording ? 140 : 108)
            }
        }
    }

    func testPhotoCaptureWaitsForReadinessAndDelivery() {
        let picker = CameraPickerStub()
        let controller = VaultSystemCameraController()
        controller.attach(picker)
        XCTAssertFalse(controller.capture())
        controller.becameReady()
        XCTAssertTrue(controller.capture())
        XCTAssertEqual(picker.photos, 1)
        XCTAssertFalse(controller.capture(), "Repeated taps must not start another capture before delivery")
        controller.finishedCapture()
        XCTAssertTrue(controller.canCapture)
    }

    func testStopRecordingWaitsForMovieDeliveryBeforeAllowingAnotherCapture() {
        let picker = CameraPickerStub()
        picker.cameraCaptureMode = .video
        let controller = VaultSystemCameraController()
        controller.attach(picker)
        controller.becameReady()
        XCTAssertTrue(controller.capture())
        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(controller.canCapture, "The shutter must remain enabled to stop recording")
        XCTAssertTrue(controller.capture())
        XCTAssertEqual(picker.videoStops, 1)
        XCTAssertFalse(controller.isRecording)
        XCTAssertTrue(controller.isCapturing, "Camera switches stay locked while the movie is finalized")
        XCTAssertFalse(controller.capture())
        controller.finishedCapture()
        XCTAssertTrue(controller.canCapture)
        XCTAssertEqual(picker.videoStarts, 1)
    }

    func testFailedRecordingStartAllowsRetry() {
        let picker = CameraPickerStub()
        picker.cameraCaptureMode = .video
        picker.canStart = false
        let controller = VaultSystemCameraController()
        controller.attach(picker)
        controller.becameReady()
        XCTAssertFalse(controller.capture())
        XCTAssertFalse(controller.isCapturing)
        XCTAssertNil(controller.recordingStartedAt)
        picker.canStart = true
        XCTAssertTrue(controller.capture())
    }

    func testStoppingSceneEndsRecordingAndIgnoresLateReadiness() {
        let picker = CameraPickerStub()
        picker.cameraCaptureMode = .video
        let delegate = CameraDelegateStub()
        picker.delegate = delegate
        let controller = VaultSystemCameraController()
        controller.attach(picker)
        controller.becameReady()
        XCTAssertTrue(controller.capture())
        controller.stop()
        XCTAssertEqual(picker.videoStops, 1)
        XCTAssertNil(picker.delegate)
        XCTAssertFalse(controller.isCapturing)
        XCTAssertFalse(controller.isRecording)
        controller.becameReady()
        XCTAssertFalse(controller.canCapture)
        XCTAssertFalse(controller.capture())
    }
}

private struct CameraPreviewProbe: UIViewControllerRepresentable {
    let state: CameraPreviewProbeState
    let video: Bool
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.preferredContentSize = video ? CGSize(width: 337.5, height: 600) : CGSize(width: 400, height: 600)
        state.view = controller.view
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) { state.view = controller.view }
}

@MainActor private final class CameraPreviewProbeState { weak var view: UIView? }

@MainActor private final class CameraPickerStub: UIImagePickerController {
    private var mode = UIImagePickerController.CameraCaptureMode.photo
    var canStart = true
    var photos = 0
    var videoStarts = 0
    var videoStops = 0
    override var cameraCaptureMode: UIImagePickerController.CameraCaptureMode {
        get { mode }
        set { mode = newValue }
    }
    override func takePicture() { photos += 1 }
    override func startVideoCapture() -> Bool { videoStarts += 1; return canStart }
    override func stopVideoCapture() { videoStops += 1 }
}

@MainActor private final class CameraDelegateStub: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {}
