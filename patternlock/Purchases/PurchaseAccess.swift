import Foundation

nonisolated enum FreeTierLimit: String, LocalizedError, Identifiable, Sendable {
    case albums, media
    var id: String { rawValue }
    var errorDescription: String? {
        switch self {
        case .albums: String(localized: "The free version includes 3 albums. Unlock Pattern Pro to create more.")
        case .media: String(localized: "The free version includes 5 items per album, including its folders. Unlock Pattern Pro to add more.")
        }
    }
}

/// Release access comes only from verified StoreKit entitlements. The optional
/// testing override is Debug-only and is never persisted as a purchase.
nonisolated final class PurchaseAccess: @unchecked Sendable {
    static let shared = PurchaseAccess(proForTesting: DeveloperSettings.enableProForTesting)
    static let freeAlbums = 3
    static let freeMediaPerAlbum = 5
    private let lock = NSLock()
    private var unlimited = false
    let isProTestingEnabled: Bool

    init(proForTesting: Bool = false) {
        #if DEBUG
        isProTestingEnabled = proForTesting
        #else
        isProTestingEnabled = false
        #endif
    }

    var isUnlimited: Bool { isProTestingEnabled || lock.withLock { unlimited } }
    func update(isUnlimited: Bool) { lock.withLock { unlimited = isUnlimited } }

    func checkAlbumCreation(currentCount: Int) throws {
        if !isUnlimited && currentCount >= Self.freeAlbums { throw FreeTierLimit.albums }
    }
    func checkMediaAddition(currentCount: Int, adding: Int = 1) throws {
        if !isUnlimited && adding > max(0, Self.freeMediaPerAlbum - currentCount) { throw FreeTierLimit.media }
    }
}
