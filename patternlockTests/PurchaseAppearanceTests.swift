import SwiftUI
import UIKit
import XCTest
@testable import patternlock

@MainActor final class PurchaseAppearanceTests: XCTestCase {
    func testSpecialOfferDoesNotOverrideItsParentColorScheme() async throws {
        let purchases = try await makeStore()
        purchases.beginSpecialOffer()
        let probe = PurchaseAppearanceProbe()
        let host = UIHostingController(rootView:
            PurchaseView(offer: .special, purchases: purchases, close: {}, showRegularOffer: {})
                .background(ColorSchemeProbe(probe: probe))
        )
        let window = try makeWindow(host)
        defer { window.isHidden = true }
        try await settle(window)
        XCTAssertEqual(probe.scheme, .light, "The special offer must not push a dark preference into its presenter.")
        capture(window, name: "Special-offer-scoped-appearance")
    }

    func testDismissingBothOffersRestoresThePresentingForm() async throws {
        let purchases = try await makeStore()
        let state = PurchasePresentationState()
        let probe = PurchaseAppearanceProbe()
        let root = FileManager.default.temporaryDirectory.appending(path: "SharingAppearance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let access = PurchaseAccess(), security = VaultSecurityState()
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), security: security, purchaseAccess: access, directory: root)
        let vault = try await auth.registerFirstVault(name: "Family", pattern: [0, 1, 2, 7, 12], gridSize: 5,
                                                     recoveryPhrase: "these eight chosen words make a sufficiently long recovery phrase")
        let library = LibraryStore(root: vault.root(in: root), security: security, purchaseAccess: access)
        await library.load()
        let transport = TestCloudTransport()
        let cloud = VaultCloudService(transport: transport, authenticator: auth)
        let host = UIHostingController(rootView: AnyView(PurchasePresentationHarness(state: state, purchases: purchases, probe: probe,
            vault: vault, library: library, cloud: cloud)))
        let window = try makeWindow(host)
        defer { window.isHidden = true }
        try await settle(window)
        XCTAssertEqual(probe.scheme, .light)
        let originalStyle = host.traitCollection.userInterfaceStyle
        capture(window, name: "Sharing-before-purchase")

        state.showingPurchase = true
        try await waitUntil { host.presentedViewController != nil }
        try await settle(window)
        XCTAssertEqual(state.flow.offer, .standard)
        capture(window, name: "Purchase-standard")

        state.flow.close(purchases: purchases)
        try await waitUntil { state.flow.offer == .special && host.presentedViewController != nil }
        try await settle(window)
        capture(window, name: "Purchase-special")

        state.flow.close(purchases: purchases)
        try await waitUntil { !state.showingPurchase && host.presentedViewController == nil }
        try await settle(window)
        XCTAssertEqual(state.dismissals, 1, "The whole purchase sequence finishes exactly once.")
        XCTAssertEqual(probe.scheme, .light)
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, originalStyle)
        XCTAssertFalse(purchases.isUnlimited)
        XCTAssertTrue(purchases.specialOffers.showsBanner())
        let cloudCalls = await transport.accountCalls
        XCTAssertEqual(cloudCalls, 0, "Viewing and cancelling the upgrade must not start sharing.")
        capture(window, name: "Sharing-form-after-both-offers")
        // Tear down SwiftUI while the test still owns its temporary library.
        host.rootView = AnyView(EmptyView())
        window.rootViewController = nil
        try await settle(window)
        withExtendedLifetime(library) {}
    }

    private func makeStore() async throws -> PurchaseStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PurchaseAppearance-" + UUID().uuidString))
        let purchases = PurchaseStore(client: TestPurchaseClient(), access: PurchaseAccess(),
                                      specialOffers: SpecialOfferStore(defaults: defaults))
        await purchases.start()
        return purchases
    }

    private func makeWindow<V: View>(_ host: UIHostingController<V>) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        return window
    }

    private func settle(_ window: UIWindow) async throws {
        window.setNeedsLayout(); window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Purchase presentation did not finish transitioning.")
    }

    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor @Observable private final class PurchasePresentationState {
    var showingPurchase = false
    let flow = PurchaseFlow(offer: nil)
    var dismissals = 0
}

@MainActor private final class PurchaseAppearanceProbe {
    var scheme: ColorScheme?
}

private struct ColorSchemeProbe: View {
    @Environment(\.colorScheme) private var scheme
    let probe: PurchaseAppearanceProbe
    var body: some View {
        Color.clear.onChange(of: scheme, initial: true) { _, value in probe.scheme = value }
    }
}

private struct PurchasePresentationHarness: View {
    @Bindable var state: PurchasePresentationState
    let purchases: PurchaseStore
    let probe: PurchaseAppearanceProbe
    let vault: Vault
    let library: LibraryStore
    let cloud: VaultCloudService
    var body: some View {
        NavigationStack {
            VaultSharingSettingsView(vault: vault, store: library, cloud: cloud, purchases: purchases)
            .background(ColorSchemeProbe(probe: probe))
            .modifier(PurchasePresentation(isPresented: $state.showingPurchase, initialOffer: .standard,
                      onDismiss: { state.dismissals += 1 }, purchases: purchases, flow: state.flow))
        }.tint(AlbumTheme.accent)
    }
}
