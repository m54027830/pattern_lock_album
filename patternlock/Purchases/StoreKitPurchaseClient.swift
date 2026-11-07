import StoreKit
import UIKit
import OSLog

@MainActor final class StoreKitPurchaseClient: LifetimePurchaseClient {
    private var product: Product?
    private var transactions: [UInt64: StoreKit.Transaction] = [:]
    #if DEBUG
    private let logger = Logger(subsystem: PurchaseConfiguration.bundleID, category: "Purchases")
    #endif

    func loadProduct() async throws -> LifetimeProduct? {
        product = nil
        #if DEBUG
        logger.notice("StoreKit requesting product \(PurchaseConfiguration.productID, privacy: .public)")
        #endif
        do {
            let products = try await Product.products(for: [PurchaseConfiguration.productID])
            product = products.first { $0.id == PurchaseConfiguration.productID && $0.type == .nonConsumable }
            #if DEBUG
            let storefront = await Storefront.current
            let country = storefront?.countryCode ?? "unknown"
            for value in products {
                logger.notice("StoreKit returned product=\(value.id, privacy: .public) price=\(value.displayPrice, privacy: .public) currency=\(value.priceFormatStyle.currencyCode, privacy: .public) storefront=\(country, privacy: .public) type=\(value.type.rawValue, privacy: .public)")
            }
            if product == nil {
                logger.notice("StoreKit returned no matching non-consumable; count=\(products.count) storefront=\(country, privacy: .public)")
            }
            #endif
            return product.map { LifetimeProduct(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice) }
        } catch {
            #if DEBUG
            let failure = error as NSError
            logger.error("StoreKit product request failed: domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            #endif
            throw error
        }
    }

    func currentEntitlements() async -> [PurchaseVerification] {
        var result: [PurchaseVerification] = []
        for await entitlement in StoreKit.Transaction.currentEntitlements(for: PurchaseConfiguration.productID) {
            result.append(map(entitlement))
        }
        return result
    }

    func purchase(in scene: UIWindowScene?) async throws -> LifetimePurchaseResult {
        guard let product, product.type == .nonConsumable else { throw PurchaseError.unavailable }
        guard let scene, scene.activationState == .foregroundActive else { throw PurchaseError.noScene }
        switch try await product.purchase(confirmIn: scene) {
        case .success(let result): return .success(map(result))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw PurchaseError.unavailable
        }
    }

    func synchronize() async throws { try await AppStore.sync() }

    func updates() -> AsyncStream<PurchaseVerification> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled, let self else { break }
                    continuation.yield(self.map(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finish(transactionID: UInt64) async {
        guard let transaction = transactions.removeValue(forKey: transactionID) else { return }
        await transaction.finish()
    }

    private func map(_ result: VerificationResult<StoreKit.Transaction>) -> PurchaseVerification {
        switch result {
        case .unverified(let transaction, _):
            return .unverified(productID: transaction.productID)
        case .verified(let transaction):
            transactions[transaction.id] = transaction
            return .verified(PurchaseTransaction(id: transaction.id, productID: transaction.productID,
                bundleID: transaction.appBundleID, isNonConsumable: transaction.productType == .nonConsumable,
                revocationDate: transaction.revocationDate, expirationDate: transaction.expirationDate,
                isUpgraded: transaction.isUpgraded))
        }
    }
}
