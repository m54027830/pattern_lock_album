import UIKit
import XCTest
@testable import patternlock

@MainActor final class VaultCameraControlTests: XCTestCase {
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
