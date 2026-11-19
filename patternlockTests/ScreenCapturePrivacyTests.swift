import UIKit
import XCTest
@testable import patternlock

@MainActor final class ScreenCapturePrivacyTests: XCTestCase {
    private func fixture(captured: Bool = false, delay: @escaping @MainActor @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(2))
    }) throws -> (UIWindowScene, UIWindow, CapturePrivacyAnchor, ScenePrivacyShield.Coordinator) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.traitOverrides.sceneCaptureState = captured ? .active : .inactive
        window.isHidden = false
        let owner = ScenePrivacyShield(onInactive: {}, onBackground: {}, onActive: {})
        let coordinator = ScenePrivacyShield.Coordinator(owner: owner, screenshotDelay: delay)
        let anchor = CapturePrivacyAnchor { [weak coordinator] in coordinator?.attach(to: $0) }
        coordinator.anchor = anchor
        coordinator.observe()
        window.rootViewController?.view.addSubview(anchor)
        window.layoutIfNeeded()
        return (scene, window, anchor, coordinator)
    }

    private func captureCover(in scene: UIWindowScene) throws -> UIWindow {
        try XCTUnwrap(scene.windows.last {
            !$0.isHidden && $0.rootViewController?.view.accessibilityIdentifier == "screenCaptureCover"
        })
    }

    func testAlreadyCapturedSceneStartsWithAnOpaqueWhiteCover() throws {
        let (scene, window, _, coordinator) = try fixture(captured: true)
        defer { coordinator.stop(); window.isHidden = true }
        let cover = try captureCover(in: scene)
        XCTAssertGreaterThan(cover.windowLevel, .alert)
        XCTAssertEqual(cover.frame, scene.effectiveGeometry.coordinateSpace.bounds)
        XCTAssertEqual(cover.rootViewController?.view.backgroundColor, UIColor.white)
        XCTAssertTrue(cover.rootViewController?.view.isOpaque == true)
        XCTAssertTrue(cover.rootViewController?.view.subviews.isEmpty == true, "Capture cover must not contain text, symbols, or vault content")
        XCTAssertTrue(cover.isUserInteractionEnabled)
        XCTAssertFalse(cover.isKeyWindow, "The cover must not steal keyboard or app-window ownership")
        coordinator.stop()
        XCTAssertTrue(cover.isHidden)
    }

    func testCaptureTraitChangesCoverPresentedContentAndSurviveActivation() async throws {
        let (scene, window, anchor, coordinator) = try fixture()
        defer { coordinator.stop(); window.isHidden = true }
        let modal = UIViewController()
        modal.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(modal, animated: false)
        anchor.removeFromSuperview()
        window.traitOverrides.sceneCaptureState = .active
        window.layoutIfNeeded()
        await Task.yield()
        let cover = try captureCover(in: scene)
        XCTAssertGreaterThan(cover.windowLevel, window.windowLevel)
        XCTAssertNotNil(window.rootViewController?.presentedViewController)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(cover.isHidden, "Returning to the app during recording must not uncover it")
        XCTAssertEqual(cover.rootViewController?.view.backgroundColor, UIColor.white)
        window.traitOverrides.sceneCaptureState = .inactive
        window.layoutIfNeeded()
        for _ in 0..<100 where !cover.isHidden { await Task.yield() }
        XCTAssertTrue(cover.isHidden)
        XCTAssertNotNil(window.rootViewController?.presentedViewController, "Capture covers the presentation without locking or dismissing the vault")
    }

    func testScreenshotCoverExpiresWithoutUncoveringAnOngoingRecording() async throws {
        var finishDelay: CheckedContinuation<Void, Never>?
        let (scene, window, _, coordinator) = try fixture(captured: true, delay: {
            await withCheckedContinuation { finishDelay = $0 }
        })
        defer { coordinator.stop(); window.isHidden = true; finishDelay?.resume() }
        let cover = try captureCover(in: scene)
        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        for _ in 0..<100 where finishDelay == nil { await Task.yield() }
        XCTAssertNotNil(finishDelay)
        finishDelay?.resume(); finishDelay = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(cover.isHidden, "The screenshot timeout must not uncover an active recording")
        window.traitOverrides.sceneCaptureState = .inactive
        window.layoutIfNeeded()
        for _ in 0..<100 where !cover.isHidden { await Task.yield() }
        XCTAssertTrue(cover.isHidden)
    }

    func testScreenshotCoverStaysUntilItsDelayAndPreservesBackgroundPrivacy() async throws {
        var finishDelay: CheckedContinuation<Void, Never>?
        let (scene, window, _, coordinator) = try fixture(captured: true, delay: {
            await withCheckedContinuation { finishDelay = $0 }
        })
        defer { coordinator.stop(); window.isHidden = true; finishDelay?.resume() }
        let cover = try captureCover(in: scene)
        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        for _ in 0..<100 where finishDelay == nil { await Task.yield() }
        window.traitOverrides.sceneCaptureState = .inactive
        window.layoutIfNeeded()
        await Task.yield()
        XCTAssertFalse(cover.isHidden, "The screenshot's white cover must remain even after recording ends")
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        finishDelay?.resume(); finishDelay = nil
        for _ in 0..<100 where cover.rootViewController?.view.accessibilityIdentifier == "screenCaptureCover" { await Task.yield() }
        XCTAssertFalse(cover.isHidden, "Expiring a screenshot cover must not expose the background app snapshot")
        XCTAssertNotEqual(cover.rootViewController?.view.accessibilityIdentifier, "screenCaptureCover")
    }
}
