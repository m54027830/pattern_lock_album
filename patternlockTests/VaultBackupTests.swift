import Foundation
import UIKit
import XCTest
@testable import patternlock

@MainActor final class VaultBackupTests: XCTestCase {
    private let phrase = "these eight chosen words make a sufficiently long recovery phrase"

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BackupTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func fixture() async throws -> (LibraryRepository, LibrarySnapshot) {
        let root = try workspace()
        let repository = LibraryRepository(root: root.appending(path: "Vault"))
        let folders = try await repository.createFolder(name: "Travel", colorIndex: 2)
        let source = root.appending(path: "source.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: source)
        let snapshot = try await repository.importFile(at: source, originalName: "private-original.jpg", kind: .photo, folderID: folders.folders[0].id)
        return (repository, snapshot)
    }

    private func backup(_ repository: LibraryRepository, _ snapshot: LibrarySnapshot) async throws -> URL {
        let url = try await VaultBackup.shared.create(name: "Private name", snapshot: snapshot, root: repository.root, phrase: phrase)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func testEncryptedBackupRoundTripPreservesBytesAndMetadata() async throws {
        let (repository, snapshot) = try await fixture()
        let item = snapshot.items[0]
        // Exercise multiple encrypted chunks, as used for large videos.
        let largeBytes = Data(repeating: 0xA7, count: 2_500_123)
        try largeBytes.write(to: repository.mediaURL(item))
        let url = try await backup(repository, snapshot)
        let encrypted = try Data(contentsOf: url)
        XCTAssertNil(encrypted.range(of: Data("Private name".utf8)))
        XCTAssertNil(encrypted.range(of: Data("private-original.jpg".utf8)))
        XCTAssertNil(encrypted.range(of: Data(phrase.utf8)))
        let restored = try await VaultBackup.shared.prepareRestore(from: url, phrase: phrase)
        XCTAssertEqual(restored.name, "Private name")
        XCTAssertEqual(restored.snapshot, snapshot)
        let reloaded = try await LibraryRepository(root: restored.directory).load()
        XCTAssertEqual(reloaded, snapshot)
        XCTAssertEqual(try Data(contentsOf: restored.directory.appending(path: "Originals/" + item.filename)), largeBytes)
        XCTAssertEqual(try Data(contentsOf: restored.directory.appending(path: "Thumbnails/" + item.id.uuidString + ".jpg")), try Data(contentsOf: repository.thumbnailURL(item)))
        let repeated = try await backup(repository, snapshot)
        XCTAssertNotEqual(try Data(contentsOf: repeated), encrypted, "Each backup uses fresh salt and nonces")
    }

    func testWrongPhraseTamperingTruncationAndTrailingDataAreRejected() async throws {
        let (repository, snapshot) = try await fixture()
        let url = try await backup(repository, snapshot)
        do { _ = try await VaultBackup.shared.prepareRestore(from: url, phrase: "wrong phrase"); XCTFail("Wrong key accepted") } catch {}
        let data = try Data(contentsOf: url)
        let root = try workspace()
        var changed = data
        changed[changed.count / 2] ^= 1
        let cases = [changed, Data(data.dropLast(10)), data + Data([0])]
        for (index, bytes) in cases.enumerated() {
            let damaged = root.appending(path: "damaged-\(index).patternbackup")
            try bytes.write(to: damaged)
            do { _ = try await VaultBackup.shared.prepareRestore(from: damaged, phrase: phrase); XCTFail("Damaged backup accepted") } catch {}
        }
        let unchanged = try await repository.load()
        XCTAssertEqual(unchanged, snapshot)
    }

    func testRestoreCreatesNewVaultAndDuplicatePatternDoesNotLeaveInstalledFiles() async throws {
        let (repository, snapshot) = try await fixture()
        let url = try await backup(repository, snapshot)
        let prepared = try await VaultBackup.shared.prepareRestore(from: url, phrase: phrase)
        let directory = try workspace()
        let storage = MemoryPatternStorage()
        let auth = PatternAuthenticator(storage: storage)
        let pattern = [0, 1, 2, 7, 12]
        _ = try await auth.register(pattern)
        do { _ = try await VaultBackup.shared.install(prepared, name: "Restored", pattern: pattern, authenticator: auth, directory: directory); XCTFail("Duplicate pattern accepted") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.directory.path))
        let newPattern = [4, 9, 14, 19, 24]
        let vault = try await VaultBackup.shared.install(prepared, name: "Restored", pattern: newPattern, authenticator: auth, directory: directory)
        let restored = try await LibraryRepository(root: vault.root(in: directory)).load()
        XCTAssertEqual(restored, snapshot)
        let unlock = try await auth.verify(newPattern)
        XCTAssertEqual(unlock, .accepted(vault))
        let original = try await auth.verify(pattern)
        XCTAssertEqual(original, .accepted(.personal))
    }

    func testEmptyVaultAndStorageUsage() async throws {
        let repository = LibraryRepository(root: try workspace())
        let snapshot = try await repository.createFolder(name: "Empty", colorIndex: 0)
        let bytes = try await repository.storageUsed()
        XCTAssertGreaterThan(bytes, 0)
        let url = try await backup(repository, snapshot)
        let restored = try await VaultBackup.shared.prepareRestore(from: url, phrase: phrase)
        XCTAssertEqual(restored.snapshot, snapshot)
        XCTAssertTrue(restored.snapshot.items.isEmpty)
    }

    func testUnsafeFilenamesAndMissingMediaCannotProduceBackup() async throws {
        let (repository, snapshot) = try await fixture()
        let item = snapshot.items[0]
        var invalid = snapshot
        invalid.items = [MediaItem(id: item.id, filename: "../escape", originalName: "escape", kind: .photo, importedAt: Date(), duration: nil, folderID: nil)]
        do { _ = try await backup(repository, invalid); XCTFail("Path traversal accepted") } catch {}
        try FileManager.default.removeItem(at: repository.mediaURL(item))
        do { _ = try await backup(repository, snapshot); XCTFail("Missing media silently omitted") } catch {}
    }
}
