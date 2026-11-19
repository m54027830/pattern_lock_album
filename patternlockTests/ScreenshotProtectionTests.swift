import SwiftUI
import UIKit
import XCTest
@testable import patternlock

@MainActor final class ScreenshotProtectionTests: XCTestCase {
    func testSecureCanvasContainsTheActualViewsAndPassesTouchesThrough() throws {
        let secure = ScreenshotProtectionView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let content = UIView()
        let button = UIButton(frame: CGRect(x: 20, y: 30, width: 100, height: 44))
        content.addSubview(button)
        secure.setContent(content)
        secure.layoutIfNeeded()
        let canvas = try XCTUnwrap(secure.secureCanvas)
        XCTAssertTrue(secure.field.isSecureTextEntry)
        XCTAssertFalse(secure.field.canBecomeFirstResponder)
        XCTAssertTrue(content.superview === canvas)
        XCTAssertTrue(content.layer.superlayer === canvas.layer, "View and layer hierarchies must remain consistent")
        XCTAssertTrue(secure.hitTest(CGPoint(x: 50, y: 50), with: nil) === button)
        for size in [CGSize(width: 320, height: 700), CGSize(width: 834, height: 1194), CGSize(width: 500, height: 700)] {
            secure.frame.size = size
            secure.setNeedsLayout(); secure.layoutIfNeeded()
            XCTAssertEqual(canvas.bounds.size, size)
            XCTAssertEqual(content.bounds.size, size)
        }
    }

    func testProtectedHostingKeepsEnvironmentTextEditingAndSheetDismissal() async throws {
        let state = ScreenshotTestState()
        let host = UIHostingController(rootView: ScreenshotTestRoot(state: state).screenshotProtected().environment(\.patternGridSize, 3))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(window)
        XCTAssertEqual(state.gridSize, 3)
        let field = try XCTUnwrap(textFields(in: host.view).first { !($0 is ScreenshotPassthroughTextField) })
        XCTAssertTrue(field.becomeFirstResponder())
        field.text = "Family"
        field.sendActions(for: .editingChanged)
        await Task.yield()
        XCTAssertEqual(state.name, "Family")
        field.resignFirstResponder()

        state.showSheet = true
        try await settle(window)
        let presented = try XCTUnwrap(presentedController(in: host))
        let presentation = try XCTUnwrap(presented.presentationController)
        XCTAssertTrue(presented.isModalInPresentation || presentation.delegate?.presentationControllerShouldDismiss?(presentation) == false,
                      "Protecting a sheet must preserve its dismissal policy")
        XCTAssertEqual(presented.sheetPresentationController?.detents.map(\.identifier), [.medium])
        XCTAssertFalse(textFields(in: presented.view).filter { $0 is ScreenshotPassthroughTextField }.isEmpty)
        XCTAssertNotNil(state.dismissSheet)
        state.dismissSheet?()
        try await settle(window)
        XCTAssertFalse(state.showSheet, "The sheet's original dismiss environment must reach its protected content")
        XCTAssertNil(presentedController(in: host))
    }

    private func settle(_ window: UIWindow) async throws {
        window.setNeedsLayout(); window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
    }

    private func textFields(in view: UIView) -> [UITextField] {
        ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    private func presentedController(in controller: UIViewController) -> UIViewController? {
        controller.presentedViewController ?? controller.children.lazy.compactMap { self.presentedController(in: $0) }.first
    }
}

@MainActor @Observable private final class ScreenshotTestState {
    var name = ""
    var gridSize = 0
    var showSheet = false
    var dismissSheet: (() -> Void)?
    deinit {}
}

private struct ScreenshotTestRoot: View {
    @Bindable var state: ScreenshotTestState
    @Environment(\.patternGridSize) private var gridSize
    var body: some View {
        NavigationStack {
            Form { TextField("Name", text: $state.name) }
                .navigationTitle("Protected content")
        }
        .onAppear { state.gridSize = gridSize }
        .protectedSheet(isPresented: $state.showSheet) { ScreenshotTestSheet(state: state) }
    }
}

private struct ScreenshotTestSheet: View {
    let state: ScreenshotTestState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Text("Protected sheet")
            .onAppear { state.dismissSheet = { dismiss() } }
            .protectedInteractiveDismissDisabled()
            .protectedPresentationDetents([.medium])
    }
}
