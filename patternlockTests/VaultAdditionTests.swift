import UIKit
import XCTest
@testable import patternlock

@MainActor final class VaultAdditionTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "VaultAdditionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testMemoAndDocumentPersistExportAndBackUpWithOriginalBytes() async throws {
        let root = try workspace()
        let repository = LibraryRepository(root: root.appending(path: "Vault"), security: VaultSecurityState(), purchaseAccess: PurchaseAccess())
        let folders = try await repository.createFolder(name: "Notes", colorIndex: 1)
        let folderID = folders.folders[0].id
        let body = "A private note\n日本語 · 한글 · 100%\n"
        _ = try await repository.createMemo(title: "Travel/notes", body: body, folderID: folderID)
        let source = root.appending(path: "contract.bin")
        let bytes = Data([0, 1, 128, 255, 17])
        try bytes.write(to: source)
        let snapshot = try await repository.importDocument(at: source, folderID: folderID)
        XCTAssertEqual(snapshot.items.map(\.kind), [.memo, .document])
        XCTAssertTrue(snapshot.items.allSatisfy { $0.folderID == folderID })
        XCTAssertEqual(snapshot.items[0].originalName, "Travel notes.txt")
        XCTAssertEqual(try String(contentsOf: repository.mediaURL(snapshot.items[0]), encoding: .utf8), body)
        XCTAssertEqual(try Data(contentsOf: repository.mediaURL(snapshot.items[1])), bytes)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.byteCount != nil && $0.fileDate != nil })
        for item in snapshot.items { XCTAssertNotNil(UIImage(contentsOfFile: repository.thumbnailURL(item).path)) }
        let reloaded = try await LibraryRepository(root: repository.root).load()
        XCTAssertEqual(reloaded, snapshot)
        let export = try await repository.export(ids: Set(snapshot.items.map(\.id)))
        defer { try? FileManager.default.removeItem(at: export) }
        XCTAssertEqual(try Data(contentsOf: export.appending(path: "contract.bin")), bytes)
        let phrase = "these eight chosen words make a sufficiently long recovery phrase"
        let archive = try await VaultBackup.shared.create(name: "Mixed vault", snapshot: snapshot, root: repository.root, phrase: phrase)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let restored = try await VaultBackup.shared.prepareRestore(from: archive, phrase: phrase)
        XCTAssertEqual(restored.snapshot, snapshot)
        for item in snapshot.items {
            XCTAssertEqual(try Data(contentsOf: restored.directory.appending(path: "Originals/" + item.filename)),
                           try Data(contentsOf: repository.mediaURL(item)))
        }
        _ = try await repository.delete(ids: Set(snapshot.items.map(\.id)))
        XCTAssertEqual(try Data(contentsOf: source), bytes, "Deleting vault copies must keep Files originals")
    }

    func testMixedKindsShareQuotaAndFailedImportLeavesNoOrphans() async throws {
        let root = try workspace()
        let source = root.appending(path: "file.dat")
        try Data([1, 2, 3]).write(to: source)
        let repository = LibraryRepository(root: root.appending(path: "Vault"), purchaseAccess: PurchaseAccess())
        for _ in 0..<4 { _ = try await repository.importDocument(at: source, folderID: nil) }
        _ = try await repository.createMemo(title: "Fifth", body: "Last free item", folderID: nil)
        do {
            _ = try await repository.createMemo(title: "Sixth", body: "Over limit", folderID: nil)
            XCTFail("Mixed items exceeded the free limit")
        } catch { XCTAssertEqual(error as? FreeTierLimit, .media) }
        let snapshot = try await repository.load()
        XCTAssertEqual(snapshot.items.count, 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.root.appending(path: "Originals").path).count, 5)
    }

    func testDocumentBatchKeepsSuccessfulImportsAndReportsMissingFile() async throws {
        let root = try workspace()
        let source = root.appending(path: "good.txt")
        try Data("keep me".utf8).write(to: source)
        let store = LibraryStore(root: root.appending(path: "Vault"), purchaseAccess: PurchaseAccess())
        await store.load()
        await store.importDocuments([source, root.appending(path: "missing.pdf")], into: nil)
        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertEqual(store.snapshot.items[0].kind, .document)
        XCTAssertTrue(store.errorMessage?.contains("missing.pdf") == true)
        XCTAssertNil(store.importSummary, "Files imports must never offer Photos original deletion")
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDocumentCommitFailureRemovesStagedVaultFiles() async throws {
        let root = try workspace()
        let source = root.appending(path: "file.txt")
        try Data("original".utf8).write(to: source)
        let repository = LibraryRepository(root: root.appending(path: "Vault"))
        _ = try await repository.load()
        try FileManager.default.createDirectory(at: repository.root.appending(path: "library.json"), withIntermediateDirectories: false)
        do { _ = try await repository.importDocument(at: source, folderID: nil); XCTFail("Commit should fail") } catch {}
        for directory in ["Originals", "Thumbnails"] {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: repository.root.appending(path: directory).path).isEmpty)
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }

    func testEmptyMemoAndFolderImportAreRejected() async throws {
        let root = try workspace()
        let repository = LibraryRepository(root: root.appending(path: "Vault"))
        do { _ = try await repository.createMemo(title: "Empty", body: " \n\t", folderID: nil); XCTFail() }
        catch { XCTAssertEqual(error as? LibraryError, .emptyMemo) }
        do { _ = try await repository.importDocument(at: root, folderID: nil); XCTFail() }
        catch { XCTAssertEqual(error as? LibraryError, .invalidDocument) }
        let snapshot = try await repository.load()
        XCTAssertTrue(snapshot.items.isEmpty)
        let unicode = try await repository.createMemo(title: String(repeating: "旅行🗺️", count: 40), body: "Unicode title", folderID: nil)
        let memo = try XCTUnwrap(unicode.items.first)
        XCTAssertLessThan(memo.originalName.utf8.count, 255)
        XCTAssertEqual(try String(contentsOf: repository.mediaURL(memo), encoding: .utf8), "Unicode title")
    }

    func testExtensionlessDocumentExportsWithoutInventingAnExtension() async throws {
        let root = try workspace()
        let source = root.appending(path: "README")
        try Data("plain text".utf8).write(to: source)
        let repository = LibraryRepository(root: root.appending(path: "Vault"))
        let snapshot = try await repository.importDocument(at: source, folderID: nil)
        let item = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(URL(fileURLWithPath: item.filename).pathExtension, "")
        let exported = try await repository.export(ids: [item.id])
        defer { try? FileManager.default.removeItem(at: exported) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appending(path: "README").path))
    }

    func testCaptureSavesToVaultAndDraftCleanupKeepsCommittedCopy() async throws {
        let root = try workspace()
        let store = LibraryStore(root: root.appending(path: "Vault"), purchaseAccess: PurchaseAccess())
        await store.load()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
        var draft: VaultFileDraft? = try VaultFileDraft.write(data, name: "Capture.jpg", kind: .photo)
        let draftURL = try XCTUnwrap(draft?.media.url)
        let saved = await store.saveCapture(try XCTUnwrap(draft), into: nil)
        XCTAssertTrue(saved)
        draft = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        let item = try XCTUnwrap(store.snapshot.items.first)
        XCTAssertEqual(try Data(contentsOf: store.repository.mediaURL(item)), data)
        XCTAssertNil(store.importSummary)
    }

    func testDiscardedDraftRemovesOnlyItsPrivateStagingDirectory() throws {
        let root = try workspace()
        let source = root.appending(path: "user-file.txt")
        try Data("keep original".utf8).write(to: source)
        var draft: VaultFileDraft? = try VaultFileDraft.copy(source, kind: .document)
        let directory = try XCTUnwrap(draft?.media.url.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        draft = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCancelledCaptureDoesNotCommitOrLeaveAnErrorForNextUnlock() async throws {
        let root = try workspace()
        let store = LibraryStore(root: root.appending(path: "Vault"), purchaseAccess: PurchaseAccess())
        await store.load()
        let draft = try VaultFileDraft.write(Data([1, 2, 3]), name: "Cancelled.jpg", kind: .photo)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.saveCapture(draft, into: nil)
        }
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertTrue(store.snapshot.items.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.repository.root.appending(path: "Originals").path).isEmpty)
    }
}
