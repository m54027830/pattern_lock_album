import SwiftUI
import UIKit
import XCTest
@testable import patternlock

@MainActor final class AdaptiveLayoutTests: XCTestCase {
    func testResizingCameraKeepsTheSamePreviewAndSafeControls() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for video in [false, true] {
            let preview = LayoutProbeState(), header = LayoutProbeState(), controls = LayoutProbeState()
            let host = UIHostingController(rootView: VaultCameraSurface(isVideo: video) {
                LayoutProbe(state: preview)
            } header: {
                LayoutProbe(state: header).frame(height: 120)
            } controls: {
                LayoutProbe(state: controls).frame(height: 100)
            })
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            var original: UIView?
            // Continuous resizing without rebuilding the root view or changing
            // capture mode: closed/open shapes, iPad, then a narrow split window.
            for size in [CGSize(width: 393, height: 852), CGSize(width: 720, height: 760),
                         CGSize(width: 1194, height: 834), CGSize(width: 320, height: 700),
                         CGSize(width: 393, height: 852)] {
                window.frame = CGRect(origin: .zero, size: size)
                host.additionalSafeAreaInsets = UIEdgeInsets(top: 12, left: 19, bottom: 8, right: 51)
                await layout(window, host: host)
                let view = try XCTUnwrap(preview.view)
                if let original { XCTAssertTrue(original === view, "Resizing must not remount a recording camera") }
                else { original = view }
                let safe = host.view.convert(host.view.safeAreaLayoutGuide.layoutFrame, to: window)
                for state in [header, controls] {
                    let control = try XCTUnwrap(state.view)
                    let frame = control.convert(control.bounds, to: window)
                    XCTAssertGreaterThanOrEqual(frame.minX, safe.minX - 0.5)
                    XCTAssertLessThanOrEqual(frame.maxX, safe.maxX + 0.5)
                    XCTAssertGreaterThanOrEqual(frame.minY, safe.minY - 0.5)
                    XCTAssertLessThanOrEqual(frame.maxY, safe.maxY + 0.5)
                }
                let frame = view.convert(view.bounds, to: window)
                if video {
                    XCTAssertEqual(frame.width, window.bounds.width, accuracy: 0.5)
                    XCTAssertEqual(frame.height, window.bounds.height, accuracy: 0.5)
                } else {
                    XCTAssertEqual(frame.minY, safe.minY + 120, accuracy: 0.5)
                    XCTAssertEqual(frame.maxY, safe.maxY - 100, accuracy: 0.5)
                }
            }
        }
    }

    func testShutterAndSoundCameraButtonsFitNarrowAndWideWindows() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let shutter = LayoutProbeState(), sound = LayoutProbeState(), flip = LayoutProbeState()
        let host = UIHostingController(rootView: CameraShutterRow {
            LayoutProbe(state: shutter)
        } options: {
            HStack(spacing: 8) {
                LayoutProbe(state: sound).frame(width: 44, height: 44)
                LayoutProbe(state: flip).frame(width: 44, height: 44)
            }
        }.padding(.horizontal, 12).frame(maxWidth: 520).frame(maxWidth: .infinity))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for width: CGFloat in [240, 320, 393, 700, 1194] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 11, bottom: 0, right: 39)
            await layout(window, host: host)
            let safe = host.view.convert(host.view.safeAreaLayoutGuide.layoutFrame, to: window)
            let frames = try [shutter, sound, flip].map { state -> CGRect in
                let view = try XCTUnwrap(state.view)
                return view.convert(view.bounds, to: window)
            }
            XCTAssertEqual(frames[0].width, 72, accuracy: 0.5)
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.minX, safe.minX - 0.5)
                XCTAssertLessThanOrEqual(frame.maxX, safe.maxX + 0.5)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
            }
            XCTAssertLessThanOrEqual(frames[0].maxX, frames[1].minX + 0.5)
            XCTAssertEqual(frames[2].minX - frames[1].maxX, 8, accuracy: 0.5, "Sound stays immediately left of camera flip")
            if safe.width >= 288 {
                XCTAssertEqual(frames[0].midX, safe.midX, accuracy: 0.5)
            }
        }
    }

    func testLibraryExpandsAndCollapsesNativeSidebar() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AdaptiveLibrary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, purchaseAccess: PurchaseAccess())
        await store.load()
        _ = await store.saveFolder(nil, name: "Travel", colorIndex: 0)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: ContentView(store: store, vaultName: "Test vault", createVault: {}, lockVault: {}))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for (size, sizeClass) in [(CGSize(width: 1194, height: 834), UIUserInterfaceSizeClass.regular),
                                  (CGSize(width: 320, height: 700), .compact),
                                  (CGSize(width: 834, height: 1194), .regular)] {
            window.frame = CGRect(origin: .zero, size: size)
            host.traitOverrides.horizontalSizeClass = sizeClass
            await layout(window, host: host)
            try await Task.sleep(for: .milliseconds(200))
            await layout(window, host: host)
            let split = try XCTUnwrap(splitController(in: host))
            XCTAssertEqual(split.isCollapsed, sizeClass == .compact)
            XCTAssertEqual(store.snapshot.folders.map(\.name), ["Travel"])
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "Library-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func splitController(in controller: UIViewController) -> UISplitViewController? {
        if let split = controller as? UISplitViewController { return split }
        return controller.children.lazy.compactMap { self.splitController(in: $0) }.first
    }

    private func layout<Content: View>(_ window: UIWindow, host: UIHostingController<Content>) async {
        for _ in 0..<4 {
            window.setNeedsLayout(); window.layoutIfNeeded()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            await Task.yield()
        }
    }
}

@MainActor private final class LayoutProbeState { weak var view: UIView? }

private struct LayoutProbe: UIViewControllerRepresentable {
    let state: LayoutProbeState
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        state.view = controller.view
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) { state.view = controller.view }
}
