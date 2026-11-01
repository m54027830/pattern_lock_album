import CoreTransferable
import Foundation
import Observation
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
    var exportSession: ExportSession?
    private var exportDirectory: URL?
    private var exportGeneration = 0
    let repository: LibraryRepository

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Vaults/Personal")) {
        repository = LibraryRepository(root: root)
    }

    func load() async {
        guard !isLoaded else { return }
        do { snapshot = try await repository.load(); isLoaded = true }
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

    func importItems(_ items: [PhotosPickerItem], into folderID: UUID?) async {
        guard !isBusy, isLoaded, !items.isEmpty else { return }
        isBusy = true
        var failed = 0
        for (index, item) in items.enumerated() {
            progress = "Importing \(index + 1) of \(items.count)…"
            do {
                guard let imported = try await item.loadTransferable(type: ImportedMedia.self) else { throw LibraryError.unsupportedMedia }
                defer { try? FileManager.default.removeItem(at: imported.url.deletingLastPathComponent()) }
                snapshot = try await repository.importFile(at: imported.url, originalName: imported.name, kind: imported.kind, folderID: folderID)
            } catch { failed += 1 }
        }
        isBusy = false
        progress = ""
        if failed > 0 { errorMessage = "\(failed) of \(items.count) items couldn’t be imported. The others were saved. Try those items again after checking that they’re downloaded in Photos." }
    }

    func export(_ ids: Set<UUID>) async {
        guard !isBusy, !ids.isEmpty else { return }
        isBusy = true
        progress = "Preparing export…"
        let generation = exportGeneration
        do {
            let directory = try await repository.export(ids: ids)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard generation == exportGeneration else {
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

    private func perform(_ operation: () async throws -> LibrarySnapshot) async -> Bool {
        guard !isBusy, isLoaded else { return false }
        isBusy = true
        defer { isBusy = false }
        do { snapshot = try await operation(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
}
