import Foundation

nonisolated enum FreeTierLimit: String, LocalizedError, Identifiable, Sendable {
    case albums, media
    var id: String { rawValue }
    var errorDescription: String? {
        switch self {
        case .albums: String(localized: "The free version includes 3 albums. Unlock Pattern Unlimited to create more.")
        case .media: String(localized: "The free version includes 5 photos or videos per album, including its folders. Unlock Pattern Unlimited to add more.")
        }
    }
}

/// Only verified StoreKit entitlements update this in-memory access state.
/// It is never restored from a preference or an unverified receipt.
nonisolated final class PurchaseAccess: @unchecked Sendable {
    static let shared = PurchaseAccess()
    static let freeAlbums = 3
    static let freeMediaPerAlbum = 5
    private let lock = NSLock()
    private var unlimited = false

    var isUnlimited: Bool { lock.withLock { unlimited } }
    func update(isUnlimited: Bool) { lock.withLock { unlimited = isUnlimited } }

    func checkAlbumCreation(currentCount: Int) throws {
        if !isUnlimited && currentCount >= Self.freeAlbums { throw FreeTierLimit.albums }
    }
    func checkMediaAddition(currentCount: Int, adding: Int = 1) throws {
        if !isUnlimited && adding > max(0, Self.freeMediaPerAlbum - currentCount) { throw FreeTierLimit.media }
    }
}
