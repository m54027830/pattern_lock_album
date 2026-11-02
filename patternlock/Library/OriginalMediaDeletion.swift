import Foundation
import Photos

@MainActor protocol OriginalMediaDeleting {
    func requestAuthorization() async throws
    func deleteOriginals(identifiers: [String]) async throws
}

nonisolated enum OriginalMediaDeletionError: LocalizedError {
    case permissionDenied, unavailableOriginals, livePhotos, missingCopies

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Photos access is needed to delete originals. Allow access in Settings, or delete them in Photos. Your vault copies are safe."
        case .unavailableOriginals:
            "Some originals aren’t accessible or can’t be deleted. Allow access to those items in Settings, or delete them in Photos. No originals were deleted."
        case .livePhotos:
            "Live Photos include motion that isn’t saved in the vault. No originals were deleted. Review your copies before deleting Live Photos in Photos."
        case .missingCopies:
            "Some vault copies are no longer available. The originals were kept in Photos."
        }
    }
}

@MainActor struct PhotoLibraryOriginalDeleter: OriginalMediaDeleting {
    nonisolated init() {}

    func requestAuthorization() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw OriginalMediaDeletionError.permissionDenied
        }
    }

    func deleteOriginals(identifiers: [String]) async throws {
        let identifiers = Set(identifiers)
        guard !identifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        guard assets.count == identifiers.count else { throw OriginalMediaDeletionError.unavailableOriginals }
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            guard asset.canPerform(.delete) else { throw OriginalMediaDeletionError.unavailableOriginals }
            // The existing image importer copies a Live Photo's still image, not its motion resource.
            guard !asset.mediaSubtypes.contains(.photoLive) else { throw OriginalMediaDeletionError.livePhotos }
        }
        // Photos presents its own deletion confirmation and commits this batch atomically.
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}

struct MediaImportSummary: Identifiable {
    let id = UUID()
    let importedCount: Int
    let failedCount: Int
    let unidentifiedCount: Int
    /// Photos identifiers are recorded only after their vault copies have committed.
    let originals: [String: UUID]

    var message: String {
        var text = "\(importedCount) \(importedCount == 1 ? "item was" : "items were") saved in this vault."
        if failedCount > 0 {
            text += " \(failedCount) couldn’t be imported; those originals will be kept."
        }
        if unidentifiedCount > 0 {
            text += " \(unidentifiedCount) saved \(unidentifiedCount == 1 ? "item couldn’t" : "items couldn’t") be linked to Photos; those originals will be kept."
        }
        if !originals.isEmpty {
            text += "\n\nKeep the originals, or delete \(originals.count == 1 ? "the original" : "the \(originals.count) originals") from Photos? Your vault copies will stay. Deletion also applies to iCloud Photos and synced devices. Deleted items may remain in Recently Deleted for up to 30 days."
        }
        return text
    }
}
