import Photos
import UIKit
import XCTest
@testable import patternlock

@MainActor final class MediaImportTests: XCTestCase {
    private func makeStore(deleter: StubOriginalDeleter) throws -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appending(path: "ImportTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LibraryStore(root: root, originalDeleter: deleter)
    }

    private func photo(_ identifier: String?) -> StubImportSource {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return StubImportSource(itemIdentifier: identifier, data: image.jpegData(compressionQuality: 1)!)
    }

    func testImportWaitsForExplicitChoiceAndKeepingOriginalsDoesNotRequestAccess() async throws {
        let deleter = StubOriginalDeleter()
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo("photo")], into: nil)
        let summary = try XCTUnwrap(store.importSummary)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(deleter.authorizationRequests, 0)
        XCTAssertTrue(deleter.deletedBatches.isEmpty)
        store.dismissImportSummary()
        await store.deleteImportedOriginals(summaryID: summary.id)
        XCTAssertEqual(deleter.authorizationRequests, 0)
        XCTAssertTrue(deleter.deletedBatches.isEmpty)
        XCTAssertEqual(store.snapshot.items.count, 1)
    }

    func testPartialImportDeletesOnlyCommittedIdentifiedOriginalsAndPreservesVaultBytes() async throws {
        let deleter = StubOriginalDeleter()
        let store = try makeStore(deleter: deleter)
        await store.load()
        let valid = photo("saved")
        await store.importItems([
            valid,
            StubImportSource(itemIdentifier: "invalid", data: Data("invalid image".utf8)),
            StubImportSource(itemIdentifier: "download-failed", data: nil),
            photo(nil)
        ], into: nil)
        let summary = try XCTUnwrap(store.importSummary)
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertEqual(summary.failedCount, 2)
        XCTAssertEqual(summary.unidentifiedCount, 1)
        XCTAssertEqual(Set(summary.originals.keys), ["saved"])
        XCTAssertNil(store.errorMessage)
        await store.deleteImportedOriginals(summaryID: summary.id)
        XCTAssertEqual(deleter.deletedBatches, [["saved"]])
        XCTAssertNil(store.importSummary)
        XCTAssertFalse(store.isBusy)
        let reloaded = try await LibraryRepository(root: store.repository.root).load()
        XCTAssertEqual(reloaded.items.count, 2)
        let saved = try XCTUnwrap(reloaded.items.first { $0.id == summary.originals["saved"] })
        XCTAssertEqual(try Data(contentsOf: store.repository.mediaURL(saved)), valid.data)
        // A completed choice cannot issue the same destructive request twice.
        await store.deleteImportedOriginals(summaryID: summary.id)
        XCTAssertEqual(deleter.deletedBatches.count, 1)
    }

    func testDuplicateIdentifiersAreDeletedOnce() async throws {
        let deleter = StubOriginalDeleter()
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo("same"), photo("same")], into: nil)
        let summary = try XCTUnwrap(store.importSummary)
        XCTAssertEqual(summary.importedCount, 2)
        await store.deleteImportedOriginals(summaryID: summary.id)
        XCTAssertEqual(deleter.deletedBatches, [["same"]])
    }

    func testFailedManifestCommitNeverOffersOriginalDeletion() async throws {
        let deleter = StubOriginalDeleter()
        let store = try makeStore(deleter: deleter)
        await store.load()
        // A directory at the manifest path makes the atomic commit fail after the media copy.
        try FileManager.default.createDirectory(at: store.repository.root.appending(path: "library.json"), withIntermediateDirectories: false)
        await store.importItems([photo("uncommitted")], into: nil)
        XCTAssertNil(store.importSummary)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.snapshot.items.isEmpty)
        XCTAssertEqual(deleter.authorizationRequests, 0)
        XCTAssertTrue(deleter.deletedBatches.isEmpty)
    }

    func testUnidentifiedImportDoesNotRequestDeletionAccess() async throws {
        let deleter = StubOriginalDeleter()
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo(nil)], into: nil)
        let summary = try XCTUnwrap(store.importSummary)
        XCTAssertTrue(summary.originals.isEmpty)
        await store.deleteImportedOriginals(summaryID: summary.id)
        XCTAssertEqual(deleter.authorizationRequests, 0)
    }

    func testDeniedPermissionKeepsVaultCopiesAndDoesNotDelete() async throws {
        let deleter = StubOriginalDeleter()
        deleter.authorizationError = OriginalMediaDeletionError.permissionDenied
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo("saved")], into: nil)
        await store.deleteImportedOriginals(summaryID: try XCTUnwrap(store.importSummary).id)
        XCTAssertEqual(deleter.authorizationRequests, 1)
        XCTAssertTrue(deleter.deletedBatches.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertFalse(store.isBusy)
    }

    func testSystemCancellationKeepsCopiesWithoutAnErrorAlert() async throws {
        let deleter = StubOriginalDeleter()
        deleter.deletionError = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo("saved")], into: nil)
        await store.deleteImportedOriginals(summaryID: try XCTUnwrap(store.importSummary).id)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertFalse(store.isBusy)
    }

    func testUnavailableOriginalsReportFailureWithoutRemovingVaultCopies() async throws {
        let deleter = StubOriginalDeleter()
        deleter.deletionError = OriginalMediaDeletionError.unavailableOriginals
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo("saved")], into: nil)
        await store.deleteImportedOriginals(summaryID: try XCTUnwrap(store.importSummary).id)
        XCTAssertNotNil(store.errorMessage)
        let item = try XCTUnwrap(store.snapshot.items.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.repository.mediaURL(item).path))
    }

    func testMissingVaultCopyPreventsOriginalDeletion() async throws {
        let deleter = StubOriginalDeleter()
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo("saved")], into: nil)
        let summary = try XCTUnwrap(store.importSummary)
        let item = try XCTUnwrap(store.snapshot.items.first)
        try FileManager.default.removeItem(at: store.repository.mediaURL(item))
        await store.deleteImportedOriginals(summaryID: summary.id)
        XCTAssertTrue(deleter.deletedBatches.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testLockDuringAuthorizationInvalidatesDeletion() async throws {
        let deleter = StubOriginalDeleter()
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo("saved")], into: nil)
        deleter.onAuthorization = { store.dismissImportSummary() }
        await store.deleteImportedOriginals(summaryID: try XCTUnwrap(store.importSummary).id)
        XCTAssertTrue(deleter.deletedBatches.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isBusy)
    }

    func testNewImportInvalidatesPreviousConfirmation() async throws {
        let deleter = StubOriginalDeleter()
        let store = try makeStore(deleter: deleter)
        await store.load()
        await store.importItems([photo("old")], into: nil)
        let oldSummary = try XCTUnwrap(store.importSummary)
        await store.importItems([photo("new")], into: nil)
        await store.deleteImportedOriginals(summaryID: oldSummary.id)
        XCTAssertTrue(deleter.deletedBatches.isEmpty)
        await store.deleteImportedOriginals(summaryID: try XCTUnwrap(store.importSummary).id)
        XCTAssertEqual(deleter.deletedBatches, [["new"]])
    }
}

private struct StubImportSource: MediaImportSource {
    let itemIdentifier: String?
    let data: Data?

    func loadImportedMedia() async throws -> ImportedMedia? {
        guard let data else { throw LibraryError.unsupportedMedia }
        let directory = FileManager.default.temporaryDirectory.appending(path: "ImportFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "photo.jpg")
        try data.write(to: url)
        return ImportedMedia(url: url, name: "photo.jpg", kind: .photo)
    }
}

@MainActor private final class StubOriginalDeleter: OriginalMediaDeleting {
    var authorizationRequests = 0
    var deletedBatches: [[String]] = []
    var authorizationError: Error?
    var deletionError: Error?
    var onAuthorization: (() -> Void)?

    func requestAuthorization() async throws {
        authorizationRequests += 1
        onAuthorization?()
        if let authorizationError { throw authorizationError }
    }

    func deleteOriginals(identifiers: [String]) async throws {
        if let deletionError { throw deletionError }
        deletedBatches.append(identifiers)
    }
}
