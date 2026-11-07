import CoreTransferable
import Foundation
import Observation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ImportedMedia: Transferable, Sendable {
    let url: URL
    let name: String
    let kind: MediaKind

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try copy(received.file, kind: .video)
        }
        FileRepresentation(importedContentType: .image) { received in
            try copy(received.file, kind: .photo)
        }
    }

    private static func copy(_ source: URL, kind: MediaKind) throws -> ImportedMedia {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let target = directory.appending(path: source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: target) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return ImportedMedia(url: target, name: source.lastPathComponent, kind: kind)
    }
}

nonisolated protocol MediaImportSource: Sendable {
    var itemIdentifier: String? { get }
    func loadImportedMedia() async throws -> ImportedMedia?
}

extension PhotosPickerItem: MediaImportSource {
    nonisolated func loadImportedMedia() async throws -> ImportedMedia? {
        try await loadTransferable(type: ImportedMedia.self)
    }
}

struct ExportSession: Identifiable {
    let id = UUID()
    let directory: URL
    let urls: [URL]
}

@MainActor @Observable
final class LibraryStore {
    private(set) var snapshot = LibrarySnapshot()
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var progress = ""
    var errorMessage: String?
    var purchaseLimit: FreeTierLimit?
    var exportSession: ExportSession?
    private(set) var importSummary: MediaImportSummary?
    private var importGeneration = 0
    private var accessRevoked = false
    private let originalDeleter: any OriginalMediaDeleting
    private var exportDirectory: URL?
    private var exportGeneration = 0
    let repository: LibraryRepository

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Vaults/Personal"), originalDeleter: any OriginalMediaDeleting = PhotoLibraryOriginalDeleter(), security: VaultSecurityState = .shared, purchaseAccess: PurchaseAccess = .shared) {
        repository = LibraryRepository(root: root, security: security, purchaseAccess: purchaseAccess)
        self.originalDeleter = originalDeleter
    }

    var isReadOnly: Bool { repository.security.isReadOnly(repository.root.lastPathComponent) }
    var allowsExport: Bool { repository.security.allowsExport(repository.root.lastPathComponent) }

    func replaceFromShare(_ prepared: PreparedVaultRestore) async throws {
        try await withExclusiveAccess {
            self.finishExport()
            self.snapshot = try await self.repository.replaceFromShare(prepared)
        }
    }

    private var canAccess: Bool { !accessRevoked && repository.security.allowsAccess(to: repository.root.lastPathComponent) }

    func load() async {
        guard !isLoaded, canAccess else { return }
        do {
            let value = try await repository.loadForDisplay()
            guard canAccess else { return }
            snapshot = value; isLoaded = true
        }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func saveFolder(_ folder: AlbumFolder?, name: String, colorIndex: Int) async -> Bool {
        await perform {
            if let folder { return try await self.repository.renameFolder(id: folder.id, name: name, colorIndex: colorIndex) }
            return try await self.repository.createFolder(name: name, colorIndex: colorIndex)
        }
    }

    @discardableResult
    func deleteFolder(_ folder: AlbumFolder) async -> Bool {
        await perform { try await self.repository.deleteFolder(id: folder.id) }
    }

    @discardableResult
    func move(_ ids: Set<UUID>, to folderID: UUID?) async -> Bool {
        await perform { try await self.repository.move(ids: ids, to: folderID) }
    }

    @discardableResult
    func delete(_ ids: Set<UUID>) async -> Bool {
        await perform { try await self.repository.delete(ids: ids) }
    }

    func importItems<Item: MediaImportSource>(_ items: [Item], into folderID: UUID?) async {
        guard canAccess, !isReadOnly, !isBusy, isLoaded, !items.isEmpty else { return }
        dismissImportSummary()
        errorMessage = nil
        let generation = importGeneration
        isBusy = true
        var failed = 0
        var limitSkipped = 0
        var importedCount = 0
        var unidentifiedCount = 0
        var originals: [String: UUID] = [:]
        for (index, item) in items.enumerated() {
            guard canAccess else { break }
            progress = String(localized: "Importing \(index + 1) of \(items.count)…")
            do {
                try repository.purchaseAccess.checkMediaAddition(currentCount: snapshot.items.count)
                guard let imported = try await item.loadImportedMedia() else { throw LibraryError.unsupportedMedia }
                defer { try? FileManager.default.removeItem(at: imported.url.deletingLastPathComponent()) }
                guard canAccess else { break }
                let value = try await repository.importFile(at: imported.url, originalName: imported.name, kind: imported.kind, folderID: folderID)
                guard canAccess else { break }
                snapshot = value
                importedCount += 1
                if let identifier = item.itemIdentifier, let savedItem = snapshot.items.last {
                    originals[identifier] = savedItem.id
                } else { unidentifiedCount += 1 }
            } catch is FreeTierLimit {
                limitSkipped = items.count - index
                break
            } catch { failed += 1 }
        }
        isBusy = false
        progress = ""
        guard canAccess, generation == importGeneration else { return }
        if importedCount > 0 {
            importSummary = MediaImportSummary(importedCount: importedCount, failedCount: failed, unidentifiedCount: unidentifiedCount, originals: originals, limitSkippedCount: limitSkipped)
        } else if limitSkipped > 0 {
            purchaseLimit = .media
        } else {
            errorMessage = String(localized: "None of the \(items.count) items could be imported. Originals were kept in Photos. Try again after checking that they’re downloaded in Photos.")
        }
    }

    func dismissImportSummary() {
        importGeneration += 1
        importSummary = nil
        purchaseLimit = nil
    }

    func saveMemo(title: String, body: String, into folderID: UUID?) async -> Bool {
        await perform { try await self.repository.createMemo(title: title, body: body, folderID: folderID) }
    }

    func saveCapture(_ draft: VaultFileDraft, into folderID: UUID?) async -> Bool {
        await perform {
            defer { withExtendedLifetime(draft) {} }
            let media = draft.media
            return try await self.repository.importFile(at: media.url, originalName: media.name, kind: media.kind, folderID: folderID)
        }
    }

    func importDocuments(_ urls: [URL], into folderID: UUID?) async {
        guard canAccess, !isReadOnly, !isBusy, isLoaded, !urls.isEmpty else { return }
        dismissImportSummary()
        errorMessage = nil
        let generation = importGeneration
        isBusy = true
        defer { isBusy = false; progress = "" }
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            guard canAccess, generation == importGeneration, !Task.isCancelled else { return }
            progress = String(localized: "Importing \(index + 1) of \(urls.count)…")
            do {
                let value = try await repository.importDocument(at: url, folderID: folderID)
                guard canAccess else { return }
                snapshot = value
            } catch is FreeTierLimit {
                if generation == importGeneration { purchaseLimit = .media }
                break
            } catch { failures.append(url.lastPathComponent) }
        }
        guard canAccess, generation == importGeneration else { return }
        if !failures.isEmpty {
            errorMessage = String(localized: "Couldn’t import: \(failures.joined(separator: ", ")). Original files were kept.")
        }
    }

    func deleteImportedOriginals(summaryID: UUID) async {
        guard canAccess, !isBusy, let summary = importSummary, summary.id == summaryID, !summary.originals.isEmpty else { return }
        let generation = importGeneration
        importSummary = nil
        isBusy = true
        progress = String(localized: "Deleting originals from Photos…")
        defer { isBusy = false; progress = "" }
        do {
            try await originalDeleter.requestAuthorization()
            // Locking, switching vaults, or backgrounding invalidates a pending request.
            guard canAccess, generation == importGeneration, !Task.isCancelled else { return }
            let copies = summary.originals.values.compactMap { id in snapshot.items.first { $0.id == id } }
            guard copies.count == summary.originals.count,
                  copies.allSatisfy({ FileManager.default.fileExists(atPath: repository.mediaURL($0).path) }) else {
                throw OriginalMediaDeletionError.missingCopies
            }
            try await originalDeleter.deleteOriginals(identifiers: summary.originals.keys.sorted())
        } catch {
            guard canAccess, generation == importGeneration else { return }
            let photoError = error as NSError
            // Cancelling the system confirmation is a normal choice to keep the originals.
            if photoError.domain == PHPhotosErrorDomain && photoError.code == PHPhotosError.Code.userCancelled.rawValue { return }
            errorMessage = String(localized: "Couldn’t delete originals. \(error.localizedDescription) Your vault copies were kept.")
        }
    }

    func export(_ ids: Set<UUID>) async {
        guard canAccess, !isBusy, !ids.isEmpty else { return }
        isBusy = true
        progress = String(localized: "Preparing export…")
        let generation = exportGeneration
        do {
            let lease = try repository.security.lease(for: repository.root.lastPathComponent)
            let directory = try await repository.export(ids: ids)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard canAccess, generation == exportGeneration, (try? repository.security.check(lease)) != nil else {
                try? FileManager.default.removeItem(at: directory)
                isBusy = false
                progress = ""
                return
            }
            exportDirectory = directory
            exportSession = ExportSession(directory: directory, urls: urls)
        } catch { errorMessage = error.localizedDescription }
        isBusy = false
        progress = ""
    }

    func finishExport() {
        exportGeneration += 1
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
        exportSession = nil
    }

    func withExclusiveAccess<T>(_ operation: () async throws -> T) async throws -> T {
        guard canAccess, !isBusy, isLoaded else { throw VaultSettingsError.busy }
        isBusy = true
        defer { isBusy = false; progress = "" }
        return try await operation()
    }

    func invalidateDeletedVault() {
        accessRevoked = true
        dismissImportSummary()
        finishExport()
        isLoaded = false
        snapshot = LibrarySnapshot()
    }

    private func perform(_ operation: () async throws -> LibrarySnapshot) async -> Bool {
        guard canAccess, !isBusy, isLoaded else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let value = try await operation()
            guard canAccess else { return false }
            snapshot = value; return true
        }
        catch is CancellationError { return false }
        catch { errorMessage = error.localizedDescription; return false }
    }
}
