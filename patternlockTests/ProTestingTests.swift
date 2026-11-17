import XCTest
@testable import patternlock

#if DEBUG
@MainActor final class ProTestingTests: XCTestCase {
    func testDebugProIsAvailableImmediatelyWithoutStoreKitOrAPurchase() async {
        let client = TestPurchaseClient()
        let access = PurchaseAccess(proForTesting: true)
        let store = PurchaseStore(client: client, access: access)
        XCTAssertTrue(store.isUnlimited)
        XCTAssertTrue(access.isProTestingEnabled)

        await store.start()
        await store.refreshEntitlements()
        await store.restore()
        await store.purchase(in: nil)
        XCTAssertTrue(store.isUnlimited)
        XCTAssertEqual(client.entitlementReads, 0)
        XCTAssertEqual(client.listenerCount, 0)
        XCTAssertEqual(client.synchronizations, 0)
        XCTAssertEqual(client.purchases, 0)
        XCTAssertTrue(client.finishes.isEmpty)
        XCTAssertFalse(store.beginSpecialOffer())
    }

    func testDebugProRemovesBothLimitsEvenWithoutAVerifiedEntitlement() throws {
        let access = PurchaseAccess(proForTesting: true)
        access.update(isUnlimited: false)
        XCTAssertTrue(access.isUnlimited)
        XCTAssertNoThrow(try access.checkAlbumCreation(currentCount: 100))
        XCTAssertNoThrow(try access.checkMediaAddition(currentCount: 100, adding: 100))
    }

    func testDisablingTheFlagDoesNotLeaveAPurchasedEntitlement() async throws {
        let testing = PurchaseAccess(proForTesting: true)
        XCTAssertTrue(testing.isUnlimited)

        let normal = PurchaseAccess(proForTesting: false)
        let client = TestPurchaseClient()
        let store = PurchaseStore(client: client, access: normal)
        await store.start()
        XCTAssertFalse(normal.isProTestingEnabled)
        XCTAssertFalse(normal.isUnlimited)
        XCTAssertFalse(store.isUnlimited)
        XCTAssertEqual(client.entitlementReads, 1)
        XCTAssertThrowsError(try normal.checkAlbumCreation(currentCount: PurchaseAccess.freeAlbums))
        XCTAssertThrowsError(try normal.checkMediaAddition(currentCount: PurchaseAccess.freeMediaPerAlbum))
    }
}
#endif
