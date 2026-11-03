import Foundation
import Observation
import UIKit

nonisolated enum PurchaseConfiguration {
    static let productID = "jp.gm.patternlock.unlimited"
    static let bundleID = "jp.gm.patternlock"
}

nonisolated struct LifetimeProduct: Equatable, Sendable {
    let id: String
    let displayName: String
    let displayPrice: String
}

nonisolated struct PurchaseTransaction: Equatable, Sendable {
    let id: UInt64
    let productID: String
    let bundleID: String
    let isNonConsumable: Bool
    let revocationDate: Date?
    let expirationDate: Date?
    let isUpgraded: Bool

    var grantsUnlimited: Bool {
        productID == PurchaseConfiguration.productID && bundleID == PurchaseConfiguration.bundleID
            && isNonConsumable && revocationDate == nil && expirationDate == nil && !isUpgraded
    }
}

nonisolated enum PurchaseVerification: Sendable {
    case verified(PurchaseTransaction)
    case unverified(productID: String)
    var productID: String {
        switch self { case .verified(let value): value.productID; case .unverified(let id): id }
    }
    var grantsUnlimited: Bool {
        if case .verified(let transaction) = self { return transaction.grantsUnlimited }
        return false
    }
}

nonisolated enum LifetimePurchaseResult: Sendable { case success(PurchaseVerification), pending, cancelled }

@MainActor protocol LifetimePurchaseClient {
    func loadProduct() async throws -> LifetimeProduct?
    func currentEntitlements() async -> [PurchaseVerification]
    func purchase(in scene: UIWindowScene?) async throws -> LifetimePurchaseResult
    func synchronize() async throws
    func updates() -> AsyncStream<PurchaseVerification>
    func finish(transactionID: UInt64) async
}

nonisolated enum PurchaseError: LocalizedError {
    case unavailable, unverified, noScene
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "The purchase is currently unavailable. Try again when the App Store is available.")
        case .unverified: String(localized: "The App Store purchase couldn’t be verified. Try Restore purchases.")
        case .noScene: String(localized: "Return to Pattern and try the purchase again.")
        }
    }
}

nonisolated enum PurchaseStatus { case checking, free, unlimited }

@MainActor @Observable final class PurchaseStore {
    static let shared = PurchaseStore()
    private(set) var status = PurchaseStatus.checking
    private(set) var product: LifetimeProduct?
    private(set) var loadingProduct = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var message: String?
    private(set) var error: String?
    var isUnlimited: Bool { status == .unlimited }
    var busy: Bool { isPurchasing || isRestoring }
    let access: PurchaseAccess
    @ObservationIgnored private let client: any LifetimePurchaseClient
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshRevision = 0

    init(client: (any LifetimePurchaseClient)? = nil, access: PurchaseAccess = .shared) {
        self.client = client ?? StoreKitPurchaseClient()
        self.access = access
    }

    func start() async {
        guard !started else { return }
        started = true
        let updates = client.updates()
        listener = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                await self?.receive(update)
            }
        }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        refreshRevision += 1
        let revision = refreshRevision
        let entitlements = await client.currentEntitlements()
        guard revision == refreshRevision, !Task.isCancelled else { return }
        setAccess(entitlements.contains(where: \.grantsUnlimited))
        for entitlement in entitlements {
            if case .verified(let transaction) = entitlement, transaction.grantsUnlimited {
                await client.finish(transactionID: transaction.id)
            }
        }
    }

    func loadProduct() async {
        guard !loadingProduct else { return }
        loadingProduct = true
        defer { loadingProduct = false }
        error = nil
        do {
            let loaded = try await client.loadProduct()
            guard loaded?.id == PurchaseConfiguration.productID else { product = nil; throw PurchaseError.unavailable }
            product = loaded
        } catch { self.error = error.localizedDescription }
    }

    func purchase(in scene: UIWindowScene?) async {
        guard !busy, !isUnlimited else { return }
        guard product != nil else { error = PurchaseError.unavailable.localizedDescription; return }
        isPurchasing = true; message = nil; error = nil
        defer { isPurchasing = false }
        do {
            switch try await client.purchase(in: scene) {
            case .cancelled: break
            case .pending:
                message = String(localized: "Your purchase is awaiting approval. Unlimited access will unlock when the App Store confirms it.")
            case .success(let verification):
                guard case .verified(let transaction) = verification, transaction.grantsUnlimited else { throw PurchaseError.unverified }
                // Grant only the signed, verified entitlement, then acknowledge delivery.
                refreshRevision += 1
                setAccess(true)
                message = String(localized: "Pattern Unlimited is unlocked.")
                await client.finish(transactionID: transaction.id)
            }
        } catch { self.error = error.localizedDescription }
    }

    func restore() async {
        guard !busy else { return }
        isRestoring = true; message = nil; error = nil
        defer { isRestoring = false }
        do {
            // This may show an Apple Account prompt; only a user action calls it.
            try await client.synchronize()
            await refreshEntitlements()
            message = isUnlimited ? String(localized: "Your one-time purchase has been restored.") : String(localized: "No Pattern Unlimited purchase was found for this Apple Account.")
        } catch { self.error = error.localizedDescription }
    }

    private func receive(_ verification: PurchaseVerification) async {
        guard verification.productID == PurchaseConfiguration.productID else { return }
        // Rebuild from current entitlements so refunds/revocations and other
        // devices are reflected, including any remaining valid shared purchase.
        await refreshEntitlements()
        if case .verified(let transaction) = verification,
           transaction.bundleID == PurchaseConfiguration.bundleID, transaction.isNonConsumable {
            await client.finish(transactionID: transaction.id)
        }
    }

    private func setAccess(_ unlimited: Bool) {
        if unlimited && status != .unlimited {
            message = String(localized: "Pattern Unlimited is unlocked.")
            error = nil
        } else if !unlimited && status == .unlimited {
            message = String(localized: "Unlimited access is no longer available. Your existing albums and media are kept.")
        }
        access.update(isUnlimited: unlimited)
        status = unlimited ? .unlimited : .free
    }

    deinit { listener?.cancel() }
}
