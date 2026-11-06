import UIKit
import XCTest
@testable import patternlock

@MainActor final class AppIconTests: XCTestCase {
    func testEveryIconHasAPreviewAndAlternatesAreRegisteredForPhoneAndPad() throws {
        let alternatives = AppIcon.allCases.compactMap(\.alternateName)
        XCTAssertEqual(alternatives.count, 9)
        XCTAssertEqual(Set(alternatives).count, 9)
        for icon in AppIcon.allCases {
            XCTAssertNotNil(UIImage(named: icon.previewAsset), icon.rawValue)
        }
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let data = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let icons = try XCTUnwrap(plist[key] as? [String: Any])
            let registered = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
            XCTAssertEqual(Set(registered.keys), Set(alternatives), key)
            for name in alternatives {
                let entry = try XCTUnwrap(registered[name] as? [String: Any])
                XCTAssertEqual(entry["CFBundleIconName"] as? String, name)
            }
        }
    }

    func testChangeAndRestoreUseSystemPreferenceAcrossStoreRelaunch() async {
        let client = IconClient()
        let store = AppIconStore(client: client)
        await store.select(.square)
        XCTAssertEqual(client.alternateIconName, "AppIconSquare")
        XCTAssertEqual(store.selected, .square)
        let reopened = AppIconStore(client: client)
        XCTAssertEqual(reopened.selected, .square)
        await reopened.select(.classic)
        XCTAssertNil(client.alternateIconName)
        XCTAssertEqual(reopened.selected, .classic)
        await reopened.select(.classic)
        XCTAssertEqual(client.calls.count, 2, "Choosing the current icon must not prompt iOS again.")
        XCTAssertFalse(reopened.isChanging)
        XCTAssertNil(reopened.errorMessage)
    }

    func testClassicCanResetAnIconRemovedByAnUpdate() async {
        let client = IconClient()
        client.alternateIconName = "RetiredIcon"
        client.shouldFail = true
        let store = AppIconStore(client: client)
        await store.select(.classic)
        XCTAssertNotNil(store.errorMessage, "An unknown icon must not be mistaken for a successful reset.")
        XCTAssertEqual(client.alternateIconName, "RetiredIcon")
        client.shouldFail = false
        await store.select(.classic)
        XCTAssertNil(client.alternateIconName)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(client.calls.count, 2)
    }

    func testFailedOrUnsupportedChangeKeepsActualIconSelected() async {
        let client = IconClient()
        client.alternateIconName = "AppIconTriangles"
        client.shouldFail = true
        let store = AppIconStore(client: client)
        await store.select(.rings)
        XCTAssertEqual(store.selected, .triangles)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isChanging)
        store.dismissError()
        XCTAssertNil(store.errorMessage)
        client.supportsAlternateIcons = false
        await store.select(.waves)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(store.selected, .triangles)
        XCTAssertNotNil(store.errorMessage)
    }

    func testCompletedChangeDoesNotShowFailureWhenSystemConfirmationFails() async {
        let client = IconClient()
        client.shouldFail = true
        client.appliesBeforeFailure = true
        let store = AppIconStore(client: client)
        await store.select(.rings)
        XCTAssertEqual(store.selected, .rings)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isChanging)
    }

    func testRapidRequestsCannotRaceTheSystemIconChange() async {
        let client = IconClient()
        client.suspend = true
        let started = expectation(description: "Icon change started")
        client.onStart = { started.fulfill() }
        let store = AppIconStore(client: client)
        let first = Task { await store.select(.mosaic) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(store.pending, .mosaic)
        XCTAssertEqual(store.selected, .classic, "Do not show success before iOS confirms it.")
        await store.select(.checker)
        XCTAssertEqual(client.calls, ["AppIconMosaic"])
        client.continuation?.resume()
        await first.value
        XCTAssertEqual(store.selected, .mosaic)
        XCTAssertFalse(store.isChanging)
    }
}

@MainActor private final class IconClient: AppIconChanging {
    var supportsAlternateIcons = true
    var alternateIconName: String?
    var calls: [String?] = []
    var shouldFail = false
    var appliesBeforeFailure = false
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    var onStart: (() -> Void)?

    func setAlternateIconName(_ name: String?) async throws {
        calls.append(name)
        if suspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                onStart?()
            }
        }
        if shouldFail {
            if appliesBeforeFailure { alternateIconName = name }
            throw CocoaError(.featureUnsupported)
        }
        alternateIconName = name
    }
}
