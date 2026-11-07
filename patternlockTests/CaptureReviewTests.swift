import UIKit
import XCTest
@testable import patternlock

@MainActor final class CaptureReviewTests: XCTestCase {
    private func store() async throws -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appending(path: "CaptureReviewTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root, purchaseAccess: PurchaseAccess())
        await store.load()
        return store
    }

    private func photo(name: String = "Capture.jpg") throws -> VaultFileDraft {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try VaultFileDraft.write(XCTUnwrap(image.jpegData(compressionQuality: 0.95)), name: name, kind: .photo)
    }

    func testCaptureIsNotInAlbumUntilUseAndSavesIntoSelectedFolder() async throws {
        let store = try await store()
        _ = await store.saveFolder(nil, name: "Selected album", colorIndex: 0)
        let folder = try XCTUnwrap(store.snapshot.folders.first)
        let review = CaptureReviewSession()
        XCTAssertTrue(review.stage(try photo()))
        XCTAssertTrue(store.snapshot.items.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.repository.root.appending(path: "Originals").path).isEmpty)
        let saved = await review.use { await store.saveCapture($0, into: folder.id) }
        XCTAssertTrue(saved)
        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertEqual(store.snapshot.items.first?.folderID, folder.id)
        XCTAssertNil(review.draft)
        XCTAssertFalse(review.isSaving)
    }

    func testRetakeDiscardsPhotoAndVideoDraftsAndOnlyUsesReplacement() async throws {
        let store = try await store()
        let review = CaptureReviewSession()
        for kind in [MediaKind.photo, .video] {
            var captured: VaultFileDraft? = try VaultFileDraft.write(Data([1, 2, 3]), name: "Retake." + kind.defaultExtension, kind: kind)
            let url = try XCTUnwrap(captured?.media.url)
            XCTAssertTrue(review.stage(try XCTUnwrap(captured)))
            captured = nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(review.discard())
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(store.snapshot.items.isEmpty)
        }
        XCTAssertTrue(review.stage(try photo(name: "Replacement.jpg")))
        let saved = await review.use { await store.saveCapture($0, into: nil) }
        XCTAssertTrue(saved)
        XCTAssertEqual(store.snapshot.items.map(\.originalName), ["Replacement.jpg"])
    }

    func testFailedSaveKeepsReviewAndDraftForRetry() async throws {
        let store = try await store()
        let review = CaptureReviewSession()
        review.stage(try photo())
        let url = try XCTUnwrap(review.draft?.media.url)
        let manifest = store.repository.root.appending(path: "library.json")
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let first = await review.use { await store.saveCapture($0, into: nil) }
        XCTAssertFalse(first)
        XCTAssertEqual(review.draft?.media.url, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.snapshot.items.isEmpty)
        XCTAssertFalse(review.isSaving)
        try FileManager.default.removeItem(at: manifest)
        let retried = await review.use { await store.saveCapture($0, into: nil) }
        XCTAssertTrue(retried)
        XCTAssertEqual(store.snapshot.items.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDoubleUseAndRetakeCannotRaceAnInFlightSave() async throws {
        let review = CaptureReviewSession()
        review.stage(try photo())
        var finish: CheckedContinuation<Bool, Never>?
        var saves = 0
        let saving = Task {
            await review.use { _ in
                saves += 1
                return await withCheckedContinuation { finish = $0 }
            }
        }
        while finish == nil { await Task.yield() }
        let second = await review.use { _ in saves += 1; return true }
        XCTAssertFalse(second)
        XCTAssertFalse(review.discard())
        XCTAssertEqual(saves, 1)
        XCTAssertNotNil(review.draft)
        finish?.resume(returning: true)
        let saved = await saving.value
        XCTAssertTrue(saved)
        XCTAssertNil(review.draft)
    }

    func testCancelClearsDraftAndLateSaveCannotReopenReview() async throws {
        let review = CaptureReviewSession()
        review.stage(try photo())
        let url = try XCTUnwrap(review.draft?.media.url)
        var finish: CheckedContinuation<Bool, Never>?
        let saving = Task {
            await review.use { _ in await withCheckedContinuation { finish = $0 } }
        }
        while finish == nil { await Task.yield() }
        review.cancel()
        XCTAssertNil(review.draft)
        finish?.resume(returning: true)
        let accepted = await saving.value
        XCTAssertFalse(accepted)
        XCTAssertNil(review.draft)
        XCTAssertFalse(review.isSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
