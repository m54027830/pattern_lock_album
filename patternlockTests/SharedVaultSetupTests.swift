import SwiftUI
import UIKit
import XCTest
@testable import patternlock

@MainActor final class SharedVaultSetupTests: XCTestCase {
    func testNameRemainsEditableOnThePatternScreen() async throws {
        var name = "Personal"
        let host = UIHostingController(rootView: NavigationStack {
            PatternSetupView(title: "Shared vault pattern", needsCurrentPattern: false,
                             vaultName: Binding(get: { name }, set: { name = $0 })) { _, _ in
                XCTFail("Editing the name must not install the vault")
            }
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<4 {
            window.layoutIfNeeded(); host.view.layoutIfNeeded()
            await Task.yield()
        }
        let field = try XCTUnwrap(textField(in: host.view))
        XCTAssertEqual(field.text, "Personal")
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(window.bounds.contains(field.convert(field.bounds, to: window)), "The name field must be visible without scrolling")
        field.text = "Family shared"
        field.sendActions(for: .editingChanged)
        await Task.yield()
        XCTAssertEqual(name, "Family shared", "Correcting the name must update the value used when joining")
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Shared-vault-pattern-name"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        return view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }
}
