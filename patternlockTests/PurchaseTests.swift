import XCTest
import StoreKit
import StoreKitTest
import UIKit
@testable import patternlock

@MainActor private final class TestPurchaseClient: LifetimePurchaseClient {
    var entitlements: [PurchaseVerification] = []
    var outcome = LifetimePurchaseResult.cancelled
    var product: LifetimeProduct? = .init(id: PurchaseConfiguration.productID, displayName: "Pattern Unlimited", displayPrice: "$9.99")
    var productFails = false
    var restoreFails = false
    var synchronizations = 0
    var purchases = 0
    var finishes: [UInt64] = []
    var listenerCount = 0
    var continuation: AsyncStream<PurchaseVerification>.Continuation?
    var deferredSnapshot: CheckedContinuation<[PurchaseVerification], Never>?
    var deferNextSnapshot = false
    var willFinish: (() -> Void)?
    func loadProduct() async throws -> LifetimeProduct? { if productFails { throw PurchaseError.unavailable }; return product }
    func currentEntitlements() async -> [PurchaseVerification] {
        if deferNextSnapshot { deferNextSnapshot = false; return await withCheckedContinuation { deferredSnapshot = $0 } }
        return entitlements
    }
    func purchase(in scene: UIWindowScene?) async throws -> LifetimePurchaseResult { purchases += 1; return outcome }
    func synchronize() async throws { synchronizations += 1; if restoreFails { throw PurchaseError.unavailable } }
    func updates() -> AsyncStream<PurchaseVerification> {
        listenerCount += 1
        return AsyncStream { continuation = $0 }
    }
    func finish(transactionID: UInt64) async { finishes.append(transactionID); willFinish?() }
}

@MainActor final class PurchaseTests: XCTestCase {
    private func transaction(id: UInt64 = 1, product: String = PurchaseConfiguration.productID,
                             bundle: String = PurchaseConfiguration.bundleID, permanent: Bool = true,
                             revoked: Date? = nil, expires: Date? = nil, upgraded: Bool = false) -> PurchaseTransaction {
        PurchaseTransaction(id: id, productID: product, bundleID: bundle, isNonConsumable: permanent,
            revocationDate: revoked, expirationDate: expires, isUpgraded: upgraded)
    }

    func testLaunchDefaultsToFreeAndStartsOneListenerWithoutAccountPrompt() async {
        let client = TestPurchaseClient(), access = PurchaseAccess(), store = PurchaseStore(client: client, access: access)
        XCTAssertFalse(access.isUnlimited)
        await store.start(); await store.start()
        XCTAssertEqual(store.status, .free)
        XCTAssertEqual(client.listenerCount, 1)
        XCTAssertEqual(client.synchronizations, 0)
        XCTAssertEqual(client.purchases, 0)
    }

    func testVerifiedCachedEntitlementUnlocksWithoutPriceOrNetworkRestore() async {
        let client = TestPurchaseClient(), access = PurchaseAccess()
        client.entitlements = [.verified(transaction())]; client.productFails = true
        let store = PurchaseStore(client: client, access: access)
        await store.start(); await store.loadProduct()
        XCTAssertTrue(store.isUnlimited)
        XCTAssertTrue(access.isUnlimited)
        XCTAssertNil(store.product)
        XCTAssertEqual(client.synchronizations, 0)
    }

    func testUnverifiedWrongProductBundleTypeAndRevokedTransactionsNeverUnlock() async {
        let invalid: [PurchaseVerification] = [.unverified(productID: PurchaseConfiguration.productID),
            .verified(transaction(product: "another.product")), .verified(transaction(bundle: "another.app")),
            .verified(transaction(permanent: false)), .verified(transaction(revoked: Date())),
            .verified(transaction(expires: .distantFuture)), .verified(transaction(upgraded: true))]
        for entitlement in invalid {
            let client = TestPurchaseClient(), access = PurchaseAccess()
            client.entitlements = [entitlement]
            let store = PurchaseStore(client: client, access: access)
            await store.start()
            XCTAssertFalse(store.isUnlimited)
            XCTAssertFalse(access.isUnlimited)
            XCTAssertTrue(client.finishes.isEmpty)
        }
    }

    func testVerifiedPurchaseDeliversBeforeFinishingAndCannotBeRepurchased() async {
        let client = TestPurchaseClient(), access = PurchaseAccess()
        client.outcome = .success(.verified(transaction()))
        client.willFinish = { XCTAssertTrue(access.isUnlimited) }
        let store = PurchaseStore(client: client, access: access)
        await store.start(); await store.loadProduct(); await store.purchase(in: nil)
        XCTAssertTrue(store.isUnlimited)
        XCTAssertEqual(client.finishes, [1])
        await store.purchase(in: nil)
        XCTAssertEqual(client.purchases, 1)
    }

    func testUnverifiedPurchaseDoesNotFinishOrUnlock() async {
        let client = TestPurchaseClient(), access = PurchaseAccess()
        client.outcome = .success(.unverified(productID: PurchaseConfiguration.productID))
        let store = PurchaseStore(client: client, access: access)
        await store.start(); await store.loadProduct(); await store.purchase(in: nil)
        XCTAssertFalse(store.isUnlimited)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(client.finishes.isEmpty)
    }

    func testCancellationAndPendingPurchaseStayFreeUntilVerifiedApprovalArrives() async {
        let client = TestPurchaseClient(), store = PurchaseStore(client: client, access: PurchaseAccess())
        await store.start(); await store.loadProduct(); await store.purchase(in: nil)
        XCTAssertFalse(store.isUnlimited)
        XCTAssertNil(store.error)
        client.outcome = .pending
        await store.purchase(in: nil)
        XCTAssertFalse(store.isUnlimited)
        XCTAssertNotNil(store.message)
        client.entitlements = [.verified(transaction())]
        client.continuation?.yield(.verified(transaction()))
        for _ in 0..<100 where !store.isUnlimited { await Task.yield() }
        XCTAssertTrue(store.isUnlimited)
    }

    func testRefundUpdateRemovesUnlimitedWhileAnotherVerifiedEntitlementCanRetainIt() async {
        let client = TestPurchaseClient(), store = PurchaseStore(client: client, access: PurchaseAccess())
        client.entitlements = [.verified(transaction())]
        await store.start()
        client.entitlements = []
        client.continuation?.yield(.verified(transaction(revoked: Date())))
        for _ in 0..<100 where store.isUnlimited { await Task.yield() }
        XCTAssertFalse(store.isUnlimited)
        client.entitlements = [.verified(transaction(id: 2))]
        client.continuation?.yield(.verified(transaction(id: 2)))
        for _ in 0..<100 where !store.isUnlimited { await Task.yield() }
        XCTAssertTrue(store.isUnlimited)
    }

    func testRestoreOnlyUnlocksWhenAValidEntitlementExists() async {
        let client = TestPurchaseClient(), store = PurchaseStore(client: client, access: PurchaseAccess())
        await store.start(); await store.restore()
        XCTAssertFalse(store.isUnlimited)
        XCTAssertEqual(client.synchronizations, 1)
        client.entitlements = [.verified(transaction())]
        await store.restore()
        XCTAssertTrue(store.isUnlimited)
        client.restoreFails = true
        await store.restore()
        XCTAssertTrue(store.isUnlimited, "A failed network restore must not erase a verified cached entitlement")
        XCTAssertNotNil(store.error)
    }

    func testLateFreeSnapshotCannotUndoVerifiedPurchase() async {
        let client = TestPurchaseClient(), store = PurchaseStore(client: client, access: PurchaseAccess())
        await store.start(); await store.loadProduct()
        client.deferNextSnapshot = true
        let refresh = Task { await store.refreshEntitlements() }
        for _ in 0..<100 where client.deferredSnapshot == nil { await Task.yield() }
        client.outcome = .success(.verified(transaction()))
        await store.purchase(in: nil)
        client.deferredSnapshot?.resume(returning: []); client.deferredSnapshot = nil
        await refresh.value
        XCTAssertTrue(store.isUnlimited)
    }

    func testUnavailableProductNeverStartsPurchase() async {
        let client = TestPurchaseClient(), store = PurchaseStore(client: client, access: PurchaseAccess())
        client.product = nil
        await store.start(); await store.loadProduct(); await store.purchase(in: nil)
        XCTAssertEqual(client.purchases, 0)
        XCTAssertNotNil(store.error)
    }

    func testFailedPriceRefreshClearsOldPriceAndRetryUsesReturnedCurrency() async {
        let client = TestPurchaseClient(), store = PurchaseStore(client: client, access: PurchaseAccess())
        await store.start(); await store.loadProduct()
        XCTAssertNotNil(store.product)
        client.productFails = true
        await store.loadProduct()
        XCTAssertNil(store.product)
        XCTAssertNotNil(store.error)
        await store.purchase(in: nil)
        XCTAssertEqual(client.purchases, 0)
        client.productFails = false
        client.product = .init(id: PurchaseConfiguration.productID, displayName: "Pattern Unlimited", displayPrice: "¥600")
        await store.loadProduct()
        XCTAssertEqual(store.product?.displayPrice, "¥600")
        XCTAssertNil(store.error)
    }
}

@MainActor final class StoreKitIntegrationTests: XCTestCase {
    func testPurchaseEntryPointVerifiesAndFinishesTheLocalNonConsumable() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Pattern", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState(); session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let store = PurchaseStore(client: StoreKitPurchaseClient(), access: PurchaseAccess())
        await store.start(); await store.loadProduct()
        let appleProducts = try await Product.products(for: ["jp.gm.patternlock.pro"])
        let appleProduct = try XCTUnwrap(appleProducts.first)
        XCTAssertEqual(store.product?.id, "jp.gm.patternlock.pro")
        XCTAssertEqual(store.product?.displayPrice, appleProduct.displayPrice, "Display StoreKit’s localized price verbatim")
        await store.purchase(in: scene)
        XCTAssertTrue(store.isUnlimited, store.error ?? "Purchase did not unlock access")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isPurchasing)
    }

    func testLocalStoreKitNonConsumablePurchaseRelaunchAndRefund() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Pattern", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState(); session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions() }
        let client = StoreKitPurchaseClient()
        let product = try await client.loadProduct()
        XCTAssertEqual(product?.id, PurchaseConfiguration.productID)
        let initial = await client.currentEntitlements()
        XCTAssertTrue(initial.isEmpty)
        let store = PurchaseStore(client: client, access: PurchaseAccess())
        await store.start()
        let purchased = try await session.buyProduct(identifier: PurchaseConfiguration.productID)
        let purchaseDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.isUnlimited && ContinuousClock.now < purchaseDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.isUnlimited, "Apple's local StoreKit signature must verify")
        let restarted = PurchaseStore(client: StoreKitPurchaseClient(), access: PurchaseAccess())
        await restarted.start()
        XCTAssertTrue(restarted.isUnlimited)
        try session.refundTransaction(identifier: UInt(purchased.id))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isUnlimited && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.isUnlimited, "The transaction update must remove refunded access")
    }
}
