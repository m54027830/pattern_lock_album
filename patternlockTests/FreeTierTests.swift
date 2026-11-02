import UIKit
import XCTest
@testable import patternlock

private struct LimitImportSource: MediaImportSource {
    let itemIdentifier: String?
    let data: Data
    func loadImportedMedia() async throws -> ImportedMedia? {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LimitImport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "photo.jpg")
        try data.write(to: url)
        return ImportedMedia(url: url, name: "photo.jpg", kind: .photo)
    }
}

@MainActor private final class LimitOriginalDeleter: OriginalMediaDeleting {
    var deleted: [String] = []
    func requestAuthorization() async throws {}
    func deleteOriginals(identifiers: [String]) async throws { deleted += identifiers }
}

@MainActor final class FreeTierTests: XCTestCase {
    private let patterns = [[0,1,2,3], [5,6,7,8], [10,11,12,13], [15,16,17,18], [20,21,22,23]]
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "FreeTier-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func imageData() throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.jpegData(compressionQuality: 0.9))
    }
    private func imageFile(in directory: URL) throws -> URL {
        let file = directory.appending(path: "source.jpg")
        try imageData().write(to: file)
        return file
    }

    func testFreeTierAllowsExactlyThreeAlbumsAndDeletionFreesASlot() async throws {
        let root = try workspace(), storage = MemoryPatternStorage(), access = PurchaseAccess()
        let auth = PatternAuthenticator(storage: storage, purchaseAccess: access, directory: root)
        _ = try await auth.register(patterns[0])
        let second = try await auth.createVault(name: "Second", pattern: patterns[1])
        _ = try await auth.createVault(name: "Third", pattern: patterns[2])
        do { _ = try await auth.createVault(name: "Fourth", pattern: patterns[3]); XCTFail() }
        catch { XCTAssertEqual(error as? FreeTierLimit, .albums) }
        try await auth.deleteVault(vaultID: second.id, currentPattern: patterns[1], directory: root)
        _ = try await auth.createVault(name: "Replacement", pattern: patterns[3])
        let count = try await auth.gridConfiguration().vaults.count
        XCTAssertEqual(count, 3)
    }

    func testConcurrentAlbumCreationCannotExceedThree() async throws {
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), purchaseAccess: PurchaseAccess())
        _ = try await auth.register(patterns[0])
        _ = try await auth.createVault(name: "Second", pattern: patterns[1])
        async let third = try? auth.createVault(name: "Third", pattern: patterns[2])
        async let fourth = try? auth.createVault(name: "Fourth", pattern: patterns[3])
        let created = await [third, fourth].compactMap { $0 }
        XCTAssertEqual(created.count, 1)
        let count = try await auth.gridConfiguration().vaults.count
        XCTAssertEqual(count, 3)
    }

    func testPaidAlbumsRemainAccessibleAfterPurchaseLossButNewCreationIsLimited() async throws {
        let access = PurchaseAccess(); access.update(isUnlimited: true)
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), purchaseAccess: access)
        _ = try await auth.register(patterns[0])
        for index in 1..<4 { _ = try await auth.createVault(name: "Album \(index)", pattern: patterns[index]) }
        access.update(isUnlimited: false)
        for pattern in patterns.prefix(4) {
            guard case .accepted = try await auth.verify(pattern) else { return XCTFail("Existing album blocked") }
        }
        do { _ = try await auth.createVault(name: "Fifth", pattern: patterns[4]); XCTFail() }
        catch { XCTAssertEqual(error as? FreeTierLimit, .albums) }
    }

    func testFiveItemLimitIncludesAllFoldersAndDeletionFreesSpace() async throws {
        let root = try workspace(), source = try imageFile(in: root)
        let repo = LibraryRepository(root: root.appending(path: "Album"), purchaseAccess: PurchaseAccess())
        let folders = try await repo.createFolder(name: "Inside", colorIndex: 0)
        let folder = try XCTUnwrap(folders.folders.first)
        var snapshot = folders
        for index in 0..<5 { snapshot = try await repo.importFile(at: source, originalName: "\(index).jpg", kind: .photo, folderID: index % 2 == 0 ? folder.id : nil) }
        do { _ = try await repo.importFile(at: source, originalName: "sixth.jpg", kind: .photo, folderID: folder.id); XCTFail() }
        catch { XCTAssertEqual(error as? FreeTierLimit, .media) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.root.appending(path: "Originals").path).count, 5)
        _ = try await repo.delete(ids: [snapshot.items[0].id])
        let result = try await repo.importFile(at: source, originalName: "replacement.jpg", kind: .photo, folderID: nil)
        XCTAssertEqual(result.items.count, 5)
    }

    func testPhotosAndVideosShareTheSameFiveItemAllowance() async throws {
        let root = try workspace(), source = try imageFile(in: root)
        var snapshot = LibrarySnapshot()
        snapshot.items = (0..<5).map { MediaItem(id: UUID(), filename: "\($0).jpg", originalName: "\($0)", kind: $0 < 2 ? .video : .photo, importedAt: Date(), duration: nil, folderID: nil) }
        try JSONEncoder().encode(snapshot).write(to: root.appending(path: "library.json"))
        let repo = LibraryRepository(root: root, purchaseAccess: PurchaseAccess())
        do { _ = try await repo.importFile(at: source, originalName: "sixth.jpg", kind: .photo, folderID: nil); XCTFail() }
        catch { XCTAssertEqual(error as? FreeTierLimit, .media) }
        let result = try await repo.load()
        XCTAssertEqual(result.items.count, 5)
    }

    func testBatchImportStopsAtLimitAndOnlyOffersDeletionOfCommittedOriginals() async throws {
        let root = try workspace(), data = try imageData(), deleter = LimitOriginalDeleter()
        let store = LibraryStore(root: root, originalDeleter: deleter, purchaseAccess: PurchaseAccess())
        await store.load()
        await store.importItems((0..<8).map { LimitImportSource(itemIdentifier: "photo\($0)", data: data) }, into: nil)
        let summary = try XCTUnwrap(store.importSummary)
        XCTAssertEqual(store.snapshot.items.count, 5)
        XCTAssertEqual(summary.importedCount, 5)
        XCTAssertEqual(summary.limitSkippedCount, 3)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(Set(summary.originals.keys), Set((0..<5).map { "photo\($0)" }))
        await store.deleteImportedOriginals(summaryID: summary.id)
        XCTAssertEqual(deleter.deleted, (0..<5).map { "photo\($0)" })
        await store.importItems([LimitImportSource(itemIdentifier: "extra", data: data)], into: nil)
        XCTAssertEqual(store.purchaseLimit, .media)
        XCTAssertNil(store.importSummary)
        XCTAssertEqual(store.snapshot.items.count, 5)
    }

    func testUnlimitedImportAndExistingExportSurviveDowngrade() async throws {
        let root = try workspace(), source = try imageFile(in: root), access = PurchaseAccess()
        access.update(isUnlimited: true)
        let repo = LibraryRepository(root: root.appending(path: "Album"), purchaseAccess: access)
        var snapshot = LibrarySnapshot()
        for index in 0..<7 { snapshot = try await repo.importFile(at: source, originalName: "\(index).jpg", kind: .photo, folderID: nil) }
        access.update(isUnlimited: false)
        let saved = try await repo.load()
        XCTAssertEqual(saved.items.count, 7)
        let export = try await repo.export(ids: Set(snapshot.items.map(\.id)))
        defer { try? FileManager.default.removeItem(at: export) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: export.path).count, 7)
        do { _ = try await repo.importFile(at: source, originalName: "eighth.jpg", kind: .photo, folderID: nil); XCTFail() }
        catch { XCTAssertEqual(error as? FreeTierLimit, .media) }
    }

    func testOversizedBackupRestoreCannotBypassMediaLimitAndCanRetryAfterUnlock() async throws {
        let root = try workspace(), source = try imageFile(in: root), access = PurchaseAccess()
        let paid = PurchaseAccess(); paid.update(isUnlimited: true)
        let prepared = root.appending(path: "Prepared")
        let repo = LibraryRepository(root: prepared, purchaseAccess: paid)
        for index in 0..<6 { _ = try await repo.importFile(at: source, originalName: "\(index).jpg", kind: .photo, folderID: nil) }
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), purchaseAccess: access, directory: root.appending(path: "Vaults"))
        _ = try await auth.register(patterns[0])
        let vault = Vault(id: UUID().uuidString, name: "Restored")
        let lease = try auth.security.lease(for: vault.id)
        do { try await auth.installRestoredVault(vault, pattern: patterns[1], preparedDirectory: prepared, directory: root.appending(path: "Vaults"), lease: lease); XCTFail() }
        catch { XCTAssertEqual(error as? FreeTierLimit, .media) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.root(in: root.appending(path: "Vaults")).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path))
        let before = try await auth.gridConfiguration().vaults.count
        XCTAssertEqual(before, 1)
        access.update(isUnlimited: true)
        try await auth.installRestoredVault(vault, pattern: patterns[1], preparedDirectory: prepared, directory: root.appending(path: "Vaults"), lease: lease)
        let result = try await auth.verify(patterns[1])
        XCTAssertEqual(result, .accepted(vault))
    }

    func testRestoreCannotBypassThreeAlbumLimit() async throws {
        let root = try workspace(), source = try imageFile(in: root), access = PurchaseAccess()
        let prepared = root.appending(path: "Prepared")
        _ = try await LibraryRepository(root: prepared, purchaseAccess: access).importFile(at: source, originalName: "photo.jpg", kind: .photo, folderID: nil)
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), purchaseAccess: access, directory: root.appending(path: "Vaults"))
        _ = try await auth.register(patterns[0])
        _ = try await auth.createVault(name: "Two", pattern: patterns[1])
        _ = try await auth.createVault(name: "Three", pattern: patterns[2])
        let vault = Vault(id: UUID().uuidString, name: "Restored")
        do { try await auth.installRestoredVault(vault, pattern: patterns[3], preparedDirectory: prepared, directory: root.appending(path: "Vaults"), lease: auth.security.lease(for: vault.id)); XCTFail() }
        catch { XCTAssertEqual(error as? FreeTierLimit, .albums) }
        let count = try await auth.gridConfiguration().vaults.count
        XCTAssertEqual(count, 3)
    }
}
