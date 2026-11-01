import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Originals and the manifest live in Application Support and participate in device backup.
/// Each future pattern vault can use its own root without changing the album model.
actor LibraryRepository {
    nonisolated let root: URL
    private var snapshot: LibrarySnapshot?
    private let files = FileManager.default

    init(root: URL) { self.root = root }

    nonisolated func mediaURL(_ item: MediaItem) -> URL {
        root.appending(path: "Originals").appending(path: item.filename)
    }

    nonisolated func thumbnailURL(_ item: MediaItem) -> URL {
        root.appending(path: "Thumbnails").appending(path: item.id.uuidString + ".jpg")
    }

    func load() throws -> LibrarySnapshot {
        if let snapshot { return snapshot }
        try files.createDirectory(at: root.appending(path: "Originals"), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        try files.createDirectory(at: root.appending(path: "Thumbnails"), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var backedUpRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try backedUpRoot.setResourceValues(values)
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

    private func commit(_ updated: LibrarySnapshot) throws -> LibrarySnapshot {
        let data = try JSONEncoder().encode(updated)
        try data.write(to: root.appending(path: "library.json"), options: [.atomic, .completeFileProtection])
        snapshot = updated
        return updated
    }

    func createFolder(name: String, colorIndex: Int) throws -> LibrarySnapshot {
        var updated = try load()
        let name = try validatedName(name, folders: updated.folders)
        updated.folders.append(AlbumFolder(id: UUID(), name: name, colorIndex: colorIndex, createdAt: Date()))
        return try commit(updated)
    }

    func renameFolder(id: UUID, name: String, colorIndex: Int) throws -> LibrarySnapshot {
        var updated = try load()
        guard let index = updated.folders.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingFolder }
        let name = try validatedName(name, folders: updated.folders.filter { $0.id != id })
        updated.folders[index].name = name
        updated.folders[index].colorIndex = colorIndex
        return try commit(updated)
    }

    /// Removing a folder keeps its originals in All media.
    func deleteFolder(id: UUID) throws -> LibrarySnapshot {
        var updated = try load()
        updated.folders.removeAll { $0.id == id }
        for index in updated.items.indices where updated.items[index].folderID == id {
            updated.items[index].folderID = nil
        }
        return try commit(updated)
    }

    func move(ids: Set<UUID>, to folderID: UUID?) throws -> LibrarySnapshot {
        var updated = try load()
        if let folderID, !updated.folders.contains(where: { $0.id == folderID }) { throw LibraryError.missingFolder }
        for index in updated.items.indices where ids.contains(updated.items[index].id) {
            updated.items[index].folderID = folderID
        }
        return try commit(updated)
    }

    func importFile(at source: URL, originalName: String, kind: MediaKind, folderID: UUID?) async throws -> LibrarySnapshot {
        _ = try load()
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? (kind == .photo ? "jpg" : "mov") : source.pathExtension
        let filename = id.uuidString + "." + ext
        let destination = root.appending(path: "Originals").appending(path: filename)
        let thumb = root.appending(path: "Thumbnails").appending(path: id.uuidString + ".jpg")
        do {
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
            } else {
                duration = nil
                guard let imageSource = CGImageSourceCreateWithURL(destination as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600
                      ] as CFDictionary) else { throw LibraryError.unsupportedMedia }
                thumbnail = image
            }
            guard let writer = CGImageDestinationCreateWithURL(thumb as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw LibraryError.unsupportedMedia }
            CGImageDestinationAddImage(writer, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw LibraryError.unsupportedMedia }
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: thumb.path)
            // Reload after AVFoundation awaits so concurrent folder edits cannot be lost.
            var updated = try load()
            let destinationFolder = updated.folders.contains { $0.id == folderID } ? folderID : nil
            updated.items.append(MediaItem(id: id, filename: filename, originalName: originalName, kind: kind, importedAt: Date(), duration: duration, folderID: destinationFolder))
            return try commit(updated)
        } catch {
            try? files.removeItem(at: destination)
            try? files.removeItem(at: thumb)
            throw error
        }
    }

    func delete(ids: Set<UUID>) throws -> LibrarySnapshot {
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
        let current = try load()
        let directory = files.temporaryDirectory.appending(path: "Export-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        do {
            for item in current.items where ids.contains(item.id) {
                let name = URL(fileURLWithPath: item.originalName).deletingPathExtension().lastPathComponent
                let ext = URL(fileURLWithPath: item.filename).pathExtension
                var target = directory.appending(path: name + "." + ext)
                var suffix = 2
                while files.fileExists(atPath: target.path) {
                    target = directory.appending(path: "\(name) (\(suffix)).\(ext)")
                    suffix += 1
                }
                try files.copyItem(at: mediaURL(item), to: target)
            }
            return directory
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    private func validatedName(_ name: String, folders: [AlbumFolder]) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { throw LibraryError.invalidName }
        guard !folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { throw LibraryError.duplicateFolder }
        return trimmed
    }
}
