import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Local originals and the manifest are excluded from device backup.
/// Restoration uses an encrypted CloudKit backup or a legacy exported archive.
actor LibraryRepository {
    nonisolated let root: URL
    nonisolated let security: VaultSecurityState
    nonisolated let purchaseAccess: PurchaseAccess
    private var snapshot: LibrarySnapshot?
    private let files = FileManager.default

    init(root: URL, security: VaultSecurityState = .shared, purchaseAccess: PurchaseAccess = .shared) { self.root = root; self.security = security; self.purchaseAccess = purchaseAccess }

    nonisolated func mediaURL(_ item: MediaItem) -> URL {
        root.appending(path: "Originals").appending(path: item.filename)
    }

    nonisolated func thumbnailURL(_ item: MediaItem) -> URL {
        root.appending(path: "Thumbnails").appending(path: item.id.uuidString + ".jpg")
    }

    func load() throws -> LibrarySnapshot {
        try security.checkAccess(to: root.lastPathComponent)
        if let snapshot { return snapshot }
        for prefix in ["ReplacingVaultOld-", "DeletingVault-", "InstallingVault-"] {
            let staged = root.deletingLastPathComponent().appending(path: prefix + root.lastPathComponent)
            if !files.fileExists(atPath: root.path), files.fileExists(atPath: staged.path) {
                try files.moveItem(at: staged, to: root)
            }
        }
        for prefix in ["ReplacingVaultOld-", "ReplacingVaultNew-"] {
            let stale = root.deletingLastPathComponent().appending(path: prefix + root.lastPathComponent)
            if files.fileExists(atPath: root.path), files.fileExists(atPath: stale.path) { try files.removeItem(at: stale) }
        }
        try LocalVaultStorage.prepareDirectory(root)
        try files.createDirectory(at: root.appending(path: "Originals"), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        try files.createDirectory(at: root.appending(path: "Thumbnails"), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let manifest = root.appending(path: "library.json")
        let loaded: LibrarySnapshot
        if files.fileExists(atPath: manifest.path) {
            do { loaded = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: manifest)) }
            catch { throw LibraryError.unreadableLibrary }
            guard loaded.version == 1 else { throw LibraryError.newerLibrary }
        } else {
            loaded = LibrarySnapshot()
        }
        // Recover an interrupted delete before exposing the library again.
        for directory in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where directory.lastPathComponent.hasPrefix("Deleting-") {
            for item in loaded.items {
                for original in [mediaURL(item), thumbnailURL(item)] {
                    let staged = directory.appending(path: original.deletingLastPathComponent().lastPathComponent).appending(path: original.lastPathComponent)
                    if files.fileExists(atPath: staged.path), !files.fileExists(atPath: original.path) {
                        try files.moveItem(at: staged, to: original)
                    }
                }
            }
            try files.removeItem(at: directory)
        }
        snapshot = loaded
        return loaded
    }

    /// Enrich older libraries without changing identifiers, ordering, or media.
    func loadForDisplay() async throws -> LibrarySnapshot {
        if security.isReadOnly(root.lastPathComponent) { return try load() }
        let pending = try load().items.filter { $0.fileDate == nil || $0.byteCount == nil }
        var metadata: [UUID: MediaFileMetadata] = [:]
        for item in pending {
            try Task.checkCancellation()
            try security.checkAccess(to: root.lastPathComponent)
            metadata[item.id] = await MediaFileMetadata.read(at: mediaURL(item), kind: item.kind)
        }
        try Task.checkCancellation()
        // Another operation may have changed the library during video metadata reads.
        let current = try load()
        var updated = current
        for index in updated.items.indices {
            guard let value = metadata[updated.items[index].id] else { continue }
            if updated.items[index].fileDate == nil { updated.items[index].fileDate = value.date }
            if updated.items[index].byteCount == nil { updated.items[index].byteCount = value.byteCount }
        }
        guard updated != current else { return current }
        do { return try commit(updated) }
        catch {
            // Optional sorting metadata must not prevent opening an intact library.
            try security.checkAccess(to: root.lastPathComponent)
            snapshot = updated
            return updated
        }
    }

    func storageUsed() throws -> Int64 {
        _ = try load()
        guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private func commit(_ updated: LibrarySnapshot) throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        try security.checkAccess(to: root.lastPathComponent)
        let data = try JSONEncoder().encode(updated)
        try data.write(to: root.appending(path: "library.json"), options: [.atomic, .completeFileProtection])
        snapshot = updated
        return updated
    }

    func createFolder(name: String, colorIndex: Int) throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        var updated = try load()
        let name = try validatedName(name, folders: updated.folders)
        updated.folders.append(AlbumFolder(id: UUID(), name: name, colorIndex: colorIndex, createdAt: Date()))
        return try commit(updated)
    }

    func renameFolder(id: UUID, name: String, colorIndex: Int) throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        var updated = try load()
        guard let index = updated.folders.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingFolder }
        let name = try validatedName(name, folders: updated.folders.filter { $0.id != id })
        updated.folders[index].name = name
        updated.folders[index].colorIndex = colorIndex
        return try commit(updated)
    }

    /// Removing a folder keeps its originals in All media.
    func deleteFolder(id: UUID) throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        var updated = try load()
        updated.folders.removeAll { $0.id == id }
        for index in updated.items.indices where updated.items[index].folderID == id {
            updated.items[index].folderID = nil
        }
        return try commit(updated)
    }

    func move(ids: Set<UUID>, to folderID: UUID?) throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        var updated = try load()
        if let folderID, !updated.folders.contains(where: { $0.id == folderID }) { throw LibraryError.missingFolder }
        for index in updated.items.indices where ids.contains(updated.items[index].id) {
            updated.items[index].folderID = folderID
        }
        return try commit(updated)
    }

    func importFile(at source: URL, originalName: String, kind: MediaKind, folderID: UUID?) async throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        try purchaseAccess.checkMediaAddition(currentCount: try load().items.count)
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? kind.defaultExtension : source.pathExtension
        let filename = id.uuidString + (ext.isEmpty ? "" : "." + ext)
        let destination = root.appending(path: "Originals").appending(path: filename)
        let thumb = root.appending(path: "Thumbnails").appending(path: id.uuidString + ".jpg")
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.invalidDocument }
            // Read the source before copying so its fallback file timestamp survives.
            let metadata = await MediaFileMetadata.read(at: source, kind: kind)
            try Task.checkCancellation()
            try security.checkAccess(to: root.lastPathComponent)
            try files.copyItem(at: source, to: destination)
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            let duration: Double?
            let thumbnail: CGImage
            if kind == .video {
                let asset = AVURLAsset(url: destination)
                let seconds = try await asset.load(.duration).seconds
                duration = seconds.isFinite ? max(0, seconds) : nil
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 600, height: 600)
                thumbnail = try await generator.image(at: .zero).image
            } else if kind == .photo {
                duration = nil
                guard let imageSource = CGImageSourceCreateWithURL(destination as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600
                      ] as CFDictionary) else { throw LibraryError.unsupportedMedia }
                thumbnail = image
            } else {
                duration = nil
                thumbnail = try VaultFileThumbnail.make(at: destination, kind: kind)
            }
            guard let writer = CGImageDestinationCreateWithURL(thumb as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw LibraryError.unsupportedMedia }
            CGImageDestinationAddImage(writer, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw LibraryError.unsupportedMedia }
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: thumb.path)
            // Reload after AVFoundation awaits so concurrent folder edits cannot be lost.
            try Task.checkCancellation()
            var updated = try load()
            // Check again after video processing: concurrent imports and a
            // purchase revocation must not let this commit exceed the limit.
            try purchaseAccess.checkMediaAddition(currentCount: updated.items.count)
            let destinationFolder = updated.folders.contains { $0.id == folderID } ? folderID : nil
            updated.items.append(MediaItem(id: id, filename: filename, originalName: originalName, kind: kind, importedAt: Date(), duration: duration, folderID: destinationFolder,
                                          fileDate: metadata.date, byteCount: metadata.byteCount))
            return try commit(updated)
        } catch {
            try? files.removeItem(at: destination)
            try? files.removeItem(at: thumb)
            throw error
        }
    }

    func delete(ids: Set<UUID>) throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        var updated = try load()
        let removed = updated.items.filter { ids.contains($0.id) }
        // Stage removals so a failed manifest write can restore the original files.
        let staging = root.appending(path: "Deleting-" + UUID().uuidString)
        try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var staged: [(URL, URL)] = []
        do {
            for item in removed {
                for url in [mediaURL(item), thumbnailURL(item)] where files.fileExists(atPath: url.path) {
                    let stagedFolder = staging.appending(path: url.deletingLastPathComponent().lastPathComponent)
                    try files.createDirectory(at: stagedFolder, withIntermediateDirectories: true)
                    let target = stagedFolder.appending(path: url.lastPathComponent)
                    try files.moveItem(at: url, to: target)
                    staged.append((url, target))
                }
            }
            updated.items.removeAll { ids.contains($0.id) }
            let result = try commit(updated)
            // A leftover staging directory is cleaned on the next launch. Once the
            // manifest is committed, never restore deleted files into the library.
            try? files.removeItem(at: staging)
            return result
        } catch {
            for (original, stagedURL) in staged where files.fileExists(atPath: stagedURL.path) {
                try? files.moveItem(at: stagedURL, to: original)
            }
            // Keep any files whose rollback failed for the next load's recovery.
            // Never discard the only copy because a filesystem operation failed.
            snapshot = nil
            throw error
        }
    }

    func export(ids: Set<UUID>) throws -> URL {
        try security.checkExport(root.lastPathComponent)
        let lease = try security.lease(for: root.lastPathComponent)
        let current = try load()
        let directory = files.temporaryDirectory.appending(path: "Export-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        do {
            for item in current.items where ids.contains(item.id) {
                try security.check(lease)
                try security.checkExport(root.lastPathComponent)
                let name = URL(fileURLWithPath: item.originalName).deletingPathExtension().lastPathComponent
                let ext = URL(fileURLWithPath: item.filename).pathExtension
                let extensionSuffix = ext.isEmpty ? "" : "." + ext
                var target = directory.appending(path: name + extensionSuffix)
                var suffix = 2
                while files.fileExists(atPath: target.path) {
                    target = directory.appending(path: "\(name) (\(suffix))" + extensionSuffix)
                    suffix += 1
                }
                try files.copyItem(at: mediaURL(item), to: target)
            }
            try security.check(lease)
            return directory
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func replaceFromShare(_ prepared: PreparedVaultRestore) throws -> LibrarySnapshot {
        let lease = try security.lease(for: root.lastPathComponent)
        try security.check(lease)
        guard security.isReadOnly(root.lastPathComponent) else { throw VaultCloudError.invalidData }
        let old = root.deletingLastPathComponent().appending(path: "ReplacingVaultOld-" + root.lastPathComponent)
        let new = root.deletingLastPathComponent().appending(path: "ReplacingVaultNew-" + root.lastPathComponent)
        _ = try load()
        try files.copyItem(at: prepared.directory, to: new)
        do {
            try security.check(lease)
            try files.moveItem(at: root, to: old)
            try files.moveItem(at: new, to: root)
        } catch {
            if !files.fileExists(atPath: root.path), files.fileExists(atPath: old.path) { try? files.moveItem(at: old, to: root) }
            try? files.removeItem(at: new)
            throw error
        }
        snapshot = prepared.snapshot
        try? files.removeItem(at: old)
        return prepared.snapshot
    }

    private func validatedName(_ name: String, folders: [AlbumFolder]) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { throw LibraryError.invalidName }
        guard !folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { throw LibraryError.duplicateFolder }
        return trimmed
    }
}
