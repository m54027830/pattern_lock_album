import XCTest
import StoreKit
import StoreKitTest
import UIKit
@testable import patternlock

@MainActor final class TestPurchaseClient: LifetimePurchaseClient {
    var entitlements: [PurchaseVerification] = []
    var outcome = LifetimePurchaseResult.cancelled
    var product: LifetimeProduct? = .init(id: PurchaseConfiguration.productID, displayName: "Pattern Pro", displayPrice: "$9.99")
    var specialProduct: LifetimeProduct? = .init(id: PurchaseConfiguration.specialProductID, displayName: "Pro Special Offer", displayPrice: "$4.99")
    var purchasedProductIDs: [String] = []
    var productFails = false
    var restoreFails = false
    var synchronizations = 0
    var purchases = 0
    var finishes: [UInt64] = []
    var listenerCount = 0
    var entitlementReads = 0
    var continuation: AsyncStream<PurchaseVerification>.Continuation?
    var deferredSnapshot: CheckedContinuation<[PurchaseVerification], Never>?
    var deferNextSnapshot = false
    var willFinish: (() -> Void)?
    func loadProduct(id: String) async throws -> LifetimeProduct? {
        if productFails { throw PurchaseError.unavailable }
        return id == PurchaseConfiguration.specialProductID ? specialProduct : product
    }
    func currentEntitlements() async -> [PurchaseVerification] {
        entitlementReads += 1
        if deferNextSnapshot { deferNextSnapshot = false; return await withCheckedContinuation { deferredSnapshot = $0 } }
        return entitlements
    }
    func purchase(productID: String, in scene: UIWindowScene?) async throws -> LifetimePurchaseResult {
        purchases += 1; purchasedProductIDs.append(productID); return outcome
    }
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
        client.product = .init(id: PurchaseConfiguration.productID, displayName: "Pattern Pro", displayPrice: "¥600")
        await store.loadProduct()
        XCTAssertEqual(store.product?.displayPrice, "¥600")
        XCTAssertNil(store.error)
    }

    func testSpecialPurchaseUsesItsOwnProductAndGrantsTheSameAccess() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let offers = SpecialOfferStore(defaults: defaults)
        let client = TestPurchaseClient(), access = PurchaseAccess()
        let store = PurchaseStore(client: client, access: access, specialOffers: offers)
        await store.start(); await store.loadProduct(); await store.loadSpecialProduct()
        XCTAssertEqual(store.product?.displayPrice, "$9.99")
        XCTAssertEqual(store.specialProduct?.displayPrice, "$4.99")
        XCTAssertTrue(store.beginSpecialOffer())
        client.outcome = .success(.verified(transaction(product: PurchaseConfiguration.specialProductID)))
        await store.purchase(in: nil, offer: .special)
        XCTAssertTrue(store.isUnlimited)
        XCTAssertTrue(access.isUnlimited)
        XCTAssertEqual(client.purchasedProductIDs, [PurchaseConfiguration.specialProductID])
        XCTAssertEqual(offers.remainingSeconds(), 0)
        XCTAssertFalse(offers.showsBanner())
        XCTAssertFalse(store.beginSpecialOffer())
        await store.purchase(in: nil)
        XCTAssertEqual(client.purchases, 1)
    }

    func testExpiredOrUnstartedSpecialNeverStartsAStoreKitPurchase() async throws {
        let offers = SpecialOfferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let client = TestPurchaseClient()
        let subject = PurchaseStore(client: client, access: PurchaseAccess(), specialOffers: offers)
        await subject.start(); await subject.loadSpecialProduct()
        await subject.purchase(in: nil, offer: .special)
        XCTAssertEqual(client.purchases, 0)
        let now = Date()
        XCTAssertTrue(subject.beginSpecialOffer(at: now))
        await subject.purchase(in: nil, offer: .special, now: now.addingTimeInterval(600))
        XCTAssertEqual(client.purchases, 0)
        XCTAssertFalse(subject.isUnlimited)
    }

    func testSpecialEntitlementRestoresAndRefundRetainsOtherValidProduct() async {
        let client = TestPurchaseClient()
        let subject = PurchaseStore(client: client, access: PurchaseAccess())
        client.entitlements = [.verified(transaction(product: PurchaseConfiguration.specialProductID))]
        await subject.start()
        XCTAssertTrue(subject.isUnlimited)
        await subject.restore()
        XCTAssertTrue(subject.isUnlimited)
        client.entitlements = [.verified(transaction(id: 2))]
        client.continuation?.yield(.verified(transaction(product: PurchaseConfiguration.specialProductID, revoked: .now)))
        for _ in 0..<100 where !client.finishes.contains(2) { await Task.yield() }
        XCTAssertTrue(subject.isUnlimited)
        client.entitlements = []
        client.continuation?.yield(.verified(transaction(id: 2, revoked: .now)))
        for _ in 0..<100 where subject.isUnlimited { await Task.yield() }
        XCTAssertFalse(subject.isUnlimited)
    }

    func testSpecialPriceRefreshClearsStalePriceWithoutClearingRegularProduct() async {
        let client = TestPurchaseClient()
        let subject = PurchaseStore(client: client, access: PurchaseAccess())
        await subject.loadProduct(); await subject.loadSpecialProduct()
        client.specialProduct = .init(id: PurchaseConfiguration.specialProductID, displayName: "Pro Special Offer", displayPrice: "¥400")
        await subject.loadSpecialProduct()
        XCTAssertEqual(subject.specialProduct?.displayPrice, "¥400")
        client.productFails = true
        await subject.loadSpecialProduct()
        XCTAssertNil(subject.specialProduct)
        XCTAssertNotNil(subject.specialProductError)
        XCTAssertNotNil(subject.product)
    }

    func testOfferFlowShowsSpecialThenBannerAndDoesNotRenewTheSameDay() async throws {
        let offers = SpecialOfferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let subject = PurchaseStore(client: TestPurchaseClient(), access: PurchaseAccess(), specialOffers: offers)
        await subject.start()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let flow = PurchaseFlow()
        flow.close(purchases: subject)
        XCTAssertNil(flow.offer, "The regular sheet must leave the screen before the special is presented.")
        XCTAssertEqual(offers.remainingSeconds(at: now), 0, "The timer starts after dismissal, not during it.")
        XCTAssertFalse(flow.presentationDidDismiss(purchases: subject, now: now))
        XCTAssertEqual(flow.offer, .special)
        XCTAssertEqual(offers.remainingSeconds(at: now), 600)
        XCTAssertFalse(offers.showsBanner(at: now))
        flow.close(purchases: subject)
        XCTAssertNil(flow.offer)
        XCTAssertTrue(flow.presentationDidDismiss(purchases: subject, now: now.addingTimeInterval(30)))
        XCTAssertTrue(offers.showsBanner(at: now.addingTimeInterval(30)))
        let reopened = PurchaseFlow(offer: .special)
        reopened.close(purchases: subject)
        XCTAssertTrue(reopened.presentationDidDismiss(purchases: subject, now: now.addingTimeInterval(40)))
        XCTAssertEqual(offers.remainingSeconds(at: now.addingTimeInterval(40)), 560)
        let sameDay = PurchaseFlow()
        sameDay.close(purchases: subject)
        XCTAssertTrue(sameDay.presentationDidDismiss(purchases: subject, now: now.addingTimeInterval(601)))
        let nextDay = PurchaseFlow()
        nextDay.close(purchases: subject)
        XCTAssertFalse(nextDay.presentationDidDismiss(purchases: subject, now: now.addingTimeInterval(86_400)))
        XCTAssertEqual(offers.remainingSeconds(at: now.addingTimeInterval(86_400)), 600)
    }

    func testPaidUserClosesRegularOfferWithoutSpecialOrBanner() async throws {
        let client = TestPurchaseClient()
        client.entitlements = [.verified(transaction(product: PurchaseConfiguration.specialProductID))]
        let offers = SpecialOfferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let subject = PurchaseStore(client: client, access: PurchaseAccess(), specialOffers: offers)
        await subject.start()
        let flow = PurchaseFlow()
        flow.close(purchases: subject)
        XCTAssertNil(flow.offer)
        XCTAssertTrue(flow.presentationDidDismiss(purchases: subject))
        XCTAssertEqual(offers.remainingSeconds(), 0)
        XCTAssertFalse(offers.showsBanner())
    }

    func testPurchaseWhileRegularSheetDismissesCancelsSpecialPresentation() async throws {
        let client = TestPurchaseClient()
        let offers = SpecialOfferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let subject = PurchaseStore(client: client, access: PurchaseAccess(), specialOffers: offers)
        await subject.start()
        let flow = PurchaseFlow()
        flow.close(purchases: subject)
        XCTAssertNil(flow.offer)
        client.entitlements = [.verified(transaction())]
        await subject.refreshEntitlements()
        XCTAssertTrue(flow.presentationDidDismiss(purchases: subject))
        XCTAssertNil(flow.offer)
        XCTAssertEqual(offers.remainingSeconds(), 0)
    }

    func testCancellingPresentationDoesNotOpenQueuedSpecial() async throws {
        let offers = SpecialOfferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let subject = PurchaseStore(client: TestPurchaseClient(), access: PurchaseAccess(), specialOffers: offers)
        await subject.start()
        let flow = PurchaseFlow()
        flow.close(purchases: subject)
        flow.cancel()
        XCTAssertTrue(flow.presentationDidDismiss(purchases: subject))
        XCTAssertNil(flow.offer)
        XCTAssertEqual(offers.remainingSeconds(), 0)
    }

    func testExpiredSpecialDismissesBeforeShowingRegularOffer() async throws {
        let subject = PurchaseStore(client: TestPurchaseClient(), access: PurchaseAccess())
        await subject.start()
        let flow = PurchaseFlow(offer: .special)
        flow.showRegularOffer()
        XCTAssertNil(flow.offer)
        XCTAssertFalse(flow.presentationDidDismiss(purchases: subject))
        XCTAssertEqual(flow.offer, .standard)
    }

    func testPendingSpecialApprovalUnlocksEvenAfterOfferExpires() async throws {
        let client = TestPurchaseClient()
        let offers = SpecialOfferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let subject = PurchaseStore(client: client, access: PurchaseAccess(), specialOffers: offers)
        await subject.start(); await subject.loadSpecialProduct()
        XCTAssertTrue(subject.beginSpecialOffer())
        client.outcome = .pending
        await subject.purchase(in: nil, offer: .special)
        XCTAssertFalse(subject.isUnlimited)
        offers.end()
        client.entitlements = [.verified(transaction(product: PurchaseConfiguration.specialProductID))]
        client.continuation?.yield(.verified(transaction(product: PurchaseConfiguration.specialProductID)))
        for _ in 0..<100 where !subject.isUnlimited { await Task.yield() }
        XCTAssertTrue(subject.isUnlimited)
        XCTAssertFalse(offers.showsBanner())
    }

    func testSpecialRejectsUnverifiedAndUnexpectedProductResults() async throws {
        let client = TestPurchaseClient()
        let offers = SpecialOfferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let subject = PurchaseStore(client: client, access: PurchaseAccess(), specialOffers: offers)
        await subject.start(); await subject.loadSpecialProduct()
        XCTAssertTrue(subject.beginSpecialOffer())
        for verification in [PurchaseVerification.unverified(productID: PurchaseConfiguration.specialProductID), .verified(transaction())] {
            client.outcome = .success(verification)
            await subject.purchase(in: nil, offer: .special)
            XCTAssertFalse(subject.isUnlimited)
            XCTAssertNotNil(subject.error)
            XCTAssertTrue(client.finishes.isEmpty)
        }
    }
}

@MainActor final class StoreKitIntegrationTests: XCTestCase {
    func testSpecialProductPurchaseRestoreAndRefundUseVerifiedStoreKitEntitlement() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Pattern", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState(); session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let offers = SpecialOfferStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let subject = PurchaseStore(client: StoreKitPurchaseClient(), access: PurchaseAccess(), specialOffers: offers)
        await subject.start(); await subject.loadProduct(); await subject.loadSpecialProduct()
        let products = try await Product.products(for: [PurchaseConfiguration.specialProductID])
        let appleProduct = try XCTUnwrap(products.first)
        XCTAssertEqual(subject.specialProduct?.id, PurchaseConfiguration.specialProductID)
        XCTAssertEqual(subject.specialProduct?.displayPrice, appleProduct.displayPrice)
        XCTAssertEqual(subject.specialProduct?.price, appleProduct.price)
        XCTAssertEqual(subject.specialProduct?.currencyCode, appleProduct.priceFormatStyle.currencyCode)
        XCTAssertTrue(subject.beginSpecialOffer())
        await subject.purchase(in: scene, offer: .special)
        XCTAssertTrue(subject.isUnlimited, subject.error ?? "Special purchase did not unlock")
        let restarted = PurchaseStore(client: StoreKitPurchaseClient(), access: PurchaseAccess())
        await restarted.start(); await restarted.restore()
        XCTAssertTrue(restarted.isUnlimited)
        let record = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: record.identifier)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while restarted.isUnlimited && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(restarted.isUnlimited)
    }

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
        XCTAssertEqual(store.product?.price, appleProduct.price)
        XCTAssertEqual(store.product?.currencyCode, appleProduct.priceFormatStyle.currencyCode)
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
