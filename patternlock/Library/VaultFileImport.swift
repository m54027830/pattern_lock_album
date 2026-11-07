import CoreGraphics
import Foundation

/// Owns only an app-created staging directory. Dropping a draft never removes a user's source file.
nonisolated final class VaultFileDraft: Sendable {
    private static let cleanedPreviousDrafts: Void = {
        let files = FileManager.default
        guard let children = try? files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for url in children where url.lastPathComponent.hasPrefix("VaultDraft-") { try? files.removeItem(at: url) }
    }()

    static func cleanTemporaryFilesOnce() { _ = cleanedPreviousDrafts }

    let media: ImportedMedia
    private let directory: URL

    private init(name: String, kind: MediaKind, write: (URL) throws -> Void) throws {
        Self.cleanTemporaryFilesOnce()
        directory = FileManager.default.temporaryDirectory.appending(path: "VaultDraft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        let url = directory.appending(path: safeName)
        do {
            try write(url)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        media = ImportedMedia(url: url, name: safeName, kind: kind)
    }

    static func write(_ data: Data, name: String, kind: MediaKind) throws -> VaultFileDraft {
        try VaultFileDraft(name: name, kind: kind) { try data.write(to: $0, options: [.atomic, .completeFileProtection]) }
    }

    static func copy(_ source: URL, kind: MediaKind) throws -> VaultFileDraft {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.invalidDocument }
        return try VaultFileDraft(name: source.lastPathComponent, kind: kind) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension LibraryRepository {
    func importDocument(at url: URL, folderID: UUID?) async throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        try purchaseAccess.checkMediaAddition(currentCount: try load().items.count)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Result<VaultFileDraft, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try VaultFileDraft.copy(readable, kind: .document) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw LibraryError.invalidDocument }
        let draft = try result.get()
        defer { withExtendedLifetime(draft) {} }
        return try await importFile(at: draft.media.url, originalName: url.lastPathComponent, kind: .document, folderID: folderID)
    }

    func createMemo(title: String, body: String, folderID: UUID?) async throws -> LibrarySnapshot {
        try security.checkWrite(root.lastPathComponent)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.emptyMemo }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = String(title.prefix(120))
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0").union(.newlines)).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Filesystem limits are in bytes; long CJK/emoji titles must still save and export.
        while name.utf8.count > 200 { name.removeLast() }
        if name.isEmpty { name = String(localized: "Memo") }
        let draft = try VaultFileDraft.write(Data(body.utf8), name: name + ".txt", kind: .memo)
        defer { withExtendedLifetime(draft) {} }
        return try await importFile(at: draft.media.url, originalName: draft.media.name, kind: .memo, folderID: folderID)
    }
}

nonisolated enum VaultFileThumbnail {
    static func make(at url: URL, kind: MediaKind) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 480, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw LibraryError.invalidDocument
        }
        context.setFillColor(CGColor(red: 0.94, green: 0.95, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 600))
        if kind == .document, url.pathExtension.lowercased() == "pdf",
           let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 600))
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 16, y: 16, width: 448, height: 568), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
        } else {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 70, y: 90, width: 340, height: 420))
            context.setStrokeColor(CGColor(red: 0.50, green: 0.61, blue: 0.53, alpha: 1))
            context.setLineWidth(8)
            for row in 0..<6 {
                context.move(to: CGPoint(x: 115, y: 435 - row * 44))
                context.addLine(to: CGPoint(x: row == 5 ? 260 : 365, y: 435 - row * 44))
            }
            context.strokePath()
        }
        guard let image = context.makeImage() else { throw LibraryError.invalidDocument }
        return image
    }
}
