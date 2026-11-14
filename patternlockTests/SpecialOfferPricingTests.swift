import XCTest
@testable import patternlock

final class SpecialOfferPricingTests: XCTestCase {
    private func product(_ amount: String, currency: String = "USD", displayPrice: String = "$9.99") -> LifetimeProduct {
        LifetimeProduct(id: "test", displayName: "Test", displayPrice: displayPrice,
                        price: Decimal(string: amount), currencyCode: currency)
    }

    func testSavingsUseNumericStorePricesAndNeverRoundUp() throws {
        for (regular, special, expected) in [("9.99", "4.99", "50"), ("10", "7.01", "29.9"),
                                              ("900", "600", "33.3"), ("10", "0", "100")] {
            let discount = try XCTUnwrap(SpecialOfferDiscount(regular: product(regular), special: product(special)))
            XCTAssertEqual(discount.percent, Decimal(string: expected))
        }
        let localized = try XCTUnwrap(SpecialOfferDiscount(
            regular: product("1200", currency: "JPY", displayPrice: "￥1,200"),
            special: product("600", currency: "JPY", displayPrice: "￥600")))
        XCTAssertEqual(localized.percent, 50)
        XCTAssertEqual(localized.regularDisplayPrice, "￥1,200", "Keep StoreKit's original formatting")
    }

    func testNoSavingsClaimForMissingMismatchedOrUndiscountedPrices() {
        XCTAssertNil(SpecialOfferDiscount(regular: nil, special: product("4.99")))
        XCTAssertNil(SpecialOfferDiscount(regular: product("9.99"), special: nil))
        XCTAssertNil(SpecialOfferDiscount(regular: product("9.99"), special: product("4.99", currency: "EUR")))
        XCTAssertNil(SpecialOfferDiscount(regular: product("0"), special: product("0")))
        XCTAssertNil(SpecialOfferDiscount(regular: product("9.99"), special: product("9.99")))
        XCTAssertNil(SpecialOfferDiscount(regular: product("9.99"), special: product("12")))
        XCTAssertNil(SpecialOfferDiscount(regular: product("9.99"), special: product("-1")))
        let displayOnly = LifetimeProduct(id: "test", displayName: "Test", displayPrice: "$9.99")
        XCTAssertNil(SpecialOfferDiscount(regular: displayOnly, special: product("4.99")))
    }
}
