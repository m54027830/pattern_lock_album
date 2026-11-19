import UIKit
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import XCTest
@testable import patternlock

@MainActor final class AppIconTests: XCTestCase {
    func testEveryIconHasAPreviewAndAlternatesAreRegisteredForPhoneAndPad() throws {
        let alternatives = AppIcon.allCases.compactMap(\.alternateName)
        XCTAssertEqual(alternatives.count, 17)
        XCTAssertEqual(Set(alternatives).count, 17)
        XCTAssertEqual(Set(AppIcon.utilityIcons + AppIcon.patternIcons + [.classic]), Set(AppIcon.allCases))
        for icon in AppIcon.allCases {
            let preview = try XCTUnwrap(UIImage(named: icon.previewAsset), icon.rawValue)
            XCTAssertEqual(preview.cgImage?.width, 1024, "Shortcut exports need full-resolution artwork: \(icon.rawValue)")
            XCTAssertEqual(preview.cgImage?.height, 1024)
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

    func testUtilityChoicesPersistWithoutChangingTheBundledAppName() async {
        let client = IconClient()
        let store = AppIconStore(client: client)
        for icon in AppIcon.utilityIcons {
            await store.select(icon)
            XCTAssertEqual(client.alternateIconName, icon.alternateName)
            XCTAssertEqual(AppIconStore(client: client).selected, icon)
            XCTAssertEqual(icon.shortcutName, icon.title)
        }
        XCTAssertEqual(client.calls.compactMap { $0 }, ["AppIconCalculator", "AppIconPrinter", "AppIconWiFi", "AppIconChatbot", "AppIconNotes", "AppIconWeather", "AppIconClock", "AppIconCompass"])
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: key) as? String, "PatternVault")
        }
        for icon in [.classic] + AppIcon.patternIcons {
            XCTAssertEqual(icon.shortcutName, "PatternVault")
        }
    }

    func testShortcutArtworkExportsAsAFullResolutionPNG() async throws {
        for icon in AppIcon.utilityIcons + [.classic] {
            let data = try await Image(icon.previewAsset).exported(as: .png)
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            let image = try XCTUnwrap(UIImage(data: data)?.cgImage, icon.rawValue)
            XCTAssertEqual(image.width, 1024, icon.rawValue)
            XCTAssertEqual(image.height, 1024, icon.rawValue)
        }
    }

    func testIconPickerRendersAtPhoneAndTabletWidths() async throws {
        let client = IconClient()
        client.alternateIconName = "AppIconChatbot"
        let store = AppIconStore(client: client)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: NavigationStack { AppIconSettingsView(icons: store) })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for size in [CGSize(width: 320, height: 852), CGSize(width: 834, height: 1194)] {
            window.frame = CGRect(origin: .zero, size: size)
            host.traitOverrides.horizontalSizeClass = size.width < 600 ? .compact : .regular
            for _ in 0..<4 {
                window.setNeedsLayout(); window.layoutIfNeeded()
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                await Task.yield()
            }
            XCTAssertEqual(store.selected, .chatbot)
            XCTAssertTrue(client.calls.isEmpty, "Showing or resizing the picker must not change the Home Screen icon")
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "AppIcons-\(Int(size.width))"
            attachment.lifetime = .keepAlways
            add(attachment)
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

    func testTemporarySystemBusyErrorRetriesAndKeepsSelectionUntilConfirmed() async {
        let client = IconClient()
        client.failures = [POSIXError(.EAGAIN), POSIXError(.EAGAIN)]
        var waits: [Duration] = []
        let store = AppIconStore(client: client, retryDelay: { waits.append($0) })
        await store.select(.calculator)
        XCTAssertEqual(client.calls, Array(repeating: "AppIconCalculator", count: 3))
        XCTAssertEqual(waits, [.milliseconds(500), .seconds(1)])
        XCTAssertEqual(store.selected, .calculator)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isChanging)
    }

    func testPersistentBusyErrorStopsAfterThreeAttemptsWithHelpfulMessage() async {
        let client = IconClient()
        client.failures = Array(repeating: POSIXError(.EAGAIN), count: 4)
        let store = AppIconStore(client: client, retryDelay: { _ in })
        await store.select(.notes)
        XCTAssertEqual(client.calls.count, 3)
        XCTAssertEqual(store.selected, .classic)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotEqual(store.errorMessage, POSIXError(.EAGAIN).localizedDescription)
        XCTAssertFalse(store.isChanging)
    }

    func testBackgroundingOrCancellationDuringRetryDoesNotSendAnotherRequest() async {
        for cancel in [false, true] {
            let client = IconClient()
            client.failures = [POSIXError(.EAGAIN)]
            let store = AppIconStore(client: client, retryDelay: { _ in
                if cancel { throw CancellationError() }
                client.isApplicationActive = false
            })
            await store.select(.clock)
            XCTAssertEqual(client.calls.count, 1)
            XCTAssertEqual(store.selected, .classic)
            XCTAssertFalse(store.isChanging)
            if cancel { XCTAssertNil(store.errorMessage) }
        }
    }

    func testDelayedSystemSuccessDoesNotTriggerAnotherChange() async {
        let client = IconClient()
        client.failures = [POSIXError(.EAGAIN)]
        let store = AppIconStore(client: client, retryDelay: { _ in client.alternateIconName = AppIcon.printer.alternateName })
        await store.select(.printer)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(store.selected, .printer)
        XCTAssertNil(store.errorMessage)
    }
}

@MainActor private final class IconClient: AppIconChanging {
    var supportsAlternateIcons = true
    var isApplicationActive = true
    var alternateIconName: String?
    var calls: [String?] = []
    var shouldFail = false
    var appliesBeforeFailure = false
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    var onStart: (() -> Void)?
    var failures: [Error] = []

    func setAlternateIconName(_ name: String?) async throws {
        calls.append(name)
        if !failures.isEmpty { throw failures.removeFirst() }
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
