import Foundation
import UIKit
import XCTest
@testable import patternlock

@MainActor final class VaultTests: XCTestCase {
    private let personalPattern = [0, 1, 2, 7, 12]
    private let travelPattern = [4, 9, 14, 19, 24]
    private let unknownPattern = [0, 5, 10, 15, 20]

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "VaultTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func photo(at url: URL, color: UIColor) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
    }

    func testDifferentPatternsOpenStableSeparateVaultsAfterRelaunch() async throws {
        let storage = MemoryPatternStorage()
        let auth = PatternAuthenticator(storage: storage)
        let personal = try await auth.register(personalPattern)
        let travel = try await auth.createVault(name: "  Travel  ", pattern: travelPattern)
        XCTAssertEqual(personal, .personal)
        XCTAssertEqual(travel.name, "Travel")
        XCTAssertNotEqual(personal.id, travel.id)
        XCTAssertNotEqual(personal.root, travel.root)
        let fresh = PatternAuthenticator(storage: storage)
        let first = try await fresh.verify(personalPattern, now: Date())
        let second = try await fresh.verify(travelPattern, now: Date())
        let unknown = try await fresh.verify(unknownPattern, now: Date())
        XCTAssertEqual(first, .accepted(personal))
        XCTAssertEqual(second, .accepted(travel))
        XCTAssertEqual(unknown, .rejected(retryAfter: nil))
        let registry = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(registry.vaults.count, 2, "An unknown pattern must never create a vault")
    }

    func testDuplicatePatternsAndNamesCannotCreateAmbiguousVaults() async throws {
        let storage = MemoryPatternStorage()
        let auth = PatternAuthenticator(storage: storage)
        _ = try await auth.register(personalPattern)
        do { _ = try await auth.createVault(name: "Travel", pattern: personalPattern); XCTFail("Reused pattern accepted") }
        catch { XCTAssertEqual(error as? PatternCredentialError, .duplicatePattern) }
        do { _ = try await auth.createVault(name: " personal ", pattern: travelPattern); XCTFail("Duplicate name accepted") }
        catch { XCTAssertEqual(error as? PatternCredentialError, .duplicateVaultName) }
        do { _ = try await auth.createVault(name: "   ", pattern: travelPattern); XCTFail("Blank name accepted") }
        catch { XCTAssertEqual(error as? PatternCredentialError, .invalidVaultName) }
        let registry = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(registry.vaults.count, 1)
    }

    func testNewVaultNeedsConfirmationAndCanBeCancelledOrSwitched() async throws {
        let auth = PatternAuthenticator(storage: MemoryPatternStorage())
        _ = try await auth.register(personalPattern)
        let lock = PatternLockStore(authenticator: auth)
        await lock.activate()
        await lock.submit(personalPattern)
        lock.beginNewVault()
        XCTAssertEqual(lock.stage, .nameVault)
        XCTAssertNil(lock.unlockedVault)
        lock.vaultName = "Travel"
        lock.continueWithVaultName()
        XCTAssertEqual(lock.stage, .create)
        await lock.submit(travelPattern)
        XCTAssertEqual(lock.stage, .confirm)
        await lock.submit(unknownPattern)
        XCTAssertEqual(lock.stage, .confirm)
        XCTAssertNil(lock.unlockedVault)
        lock.cancelNewVault()
        XCTAssertEqual(lock.unlockedVault, .personal)
        let notCreated = try await auth.verify(travelPattern, now: Date())
        XCTAssertEqual(notCreated, .rejected(retryAfter: nil))
        lock.beginNewVault()
        lock.vaultName = "Travel"
        lock.continueWithVaultName()
        await lock.submit(travelPattern)
        await lock.submit(travelPattern)
        let travel = try XCTUnwrap(lock.unlockedVault)
        XCTAssertEqual(travel.name, "Travel")
        XCTAssertEqual(lock.stage, .unlocked)
        lock.lock()
        XCTAssertNil(lock.unlockedVault)
        await lock.activate()
        await lock.submit(personalPattern)
        XCTAssertEqual(lock.unlockedVault, .personal)
        lock.enteredBackground()
        await lock.activate()
        await lock.submit(travelPattern)
        XCTAssertEqual(lock.unlockedVault, travel)
    }

    func testDuplicatePatternReturnsToCreationAndKeepsExistingVaultUsable() async throws {
        let auth = PatternAuthenticator(storage: MemoryPatternStorage())
        _ = try await auth.register(personalPattern)
        let lock = PatternLockStore(authenticator: auth)
        await lock.activate()
        await lock.submit(personalPattern)
        lock.beginNewVault()
        lock.vaultName = "Travel"
        lock.continueWithVaultName()
        await lock.submit(personalPattern)
        await lock.submit(personalPattern)
        XCTAssertEqual(lock.stage, .create)
        XCTAssertTrue(lock.isCreatingVault)
        XCTAssertNotNil(lock.message)
        XCTAssertNil(lock.unlockedVault)
        lock.cancelNewVault()
        XCTAssertEqual(lock.unlockedVault, .personal)
    }

    func testBackgroundDuringVaultCreationDiscardsPendingPatternAndReturnAccess() async throws {
        let storage = MemoryPatternStorage()
        let auth = PatternAuthenticator(storage: storage)
        _ = try await auth.register(personalPattern)
        let lock = PatternLockStore(authenticator: auth)
        await lock.activate()
        await lock.submit(personalPattern)
        lock.beginNewVault()
        lock.vaultName = "Travel"
        lock.continueWithVaultName()
        await lock.submit(travelPattern)
        lock.enteredBackground()
        lock.cancelNewVault()
        XCTAssertNil(lock.unlockedVault)
        await lock.activate()
        XCTAssertEqual(lock.stage, .locked)
        XCTAssertFalse(lock.isCreatingVault)
        await lock.submit(travelPattern)
        XCTAssertEqual(lock.stage, .locked)
        let registry = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(registry.vaults.count, 1)
    }

    func testLegacyCredentialMigratesWithoutChangingExistingLibrary() async throws {
        let root = try workspace()
        let oldLibrary = LibraryRepository(root: Vault.personal.root(in: root))
        let previous = try await oldLibrary.createFolder(name: "Already here", colorIndex: 3)
        let fixtureStorage = MemoryPatternStorage()
        let fixture = PatternAuthenticator(storage: fixtureStorage)
        _ = try await fixture.register(personalPattern)
        var legacy = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(fixtureStorage.read())).vaults[0].pattern
        let now = Date()
        legacy.failedAttempts = 5
        legacy.retryAfter = now.addingTimeInterval(30)
        let storage = MemoryPatternStorage(data: try JSONEncoder().encode(legacy))
        let migrated = PatternAuthenticator(storage: storage)
        let status = try await migrated.status()
        XCTAssertTrue(status.isRegistered)
        XCTAssertEqual(status.retryAfter, legacy.retryAfter)
        let result = try await migrated.verify(personalPattern, now: now.addingTimeInterval(31))
        XCTAssertEqual(result, .accepted(.personal))
        let library = try await LibraryRepository(root: Vault.personal.root(in: root)).load()
        XCTAssertEqual(library, previous)
        let travel = try await migrated.createVault(name: "Travel", pattern: travelPattern)
        let empty = try await LibraryRepository(root: travel.root(in: root)).load()
        XCTAssertTrue(empty.folders.isEmpty)
        XCTAssertTrue(empty.items.isEmpty)
        let upgraded = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(upgraded.version, 2)
        XCTAssertEqual(upgraded.vaults.count, 2)
    }

    func testPhotosFoldersDeletionAndExportsAreIsolatedPerVault() async throws {
        let root = try workspace()
        let firstSource = root.appending(path: "red.jpg")
        let secondSource = root.appending(path: "blue.jpg")
        try photo(at: firstSource, color: .red)
        try photo(at: secondSource, color: .blue)
        let travel = Vault(id: UUID().uuidString, name: "Travel")
        let libraries = VaultLibraries(directory: root.appending(path: "Vaults"))
        let personalStore = libraries.store(for: .personal)
        let travelStore = libraries.store(for: travel)
        XCTAssertFalse(personalStore === travelStore)
        XCTAssertTrue(libraries.store(for: .personal) === personalStore)
        let firstRepo = personalStore.repository
        let secondRepo = travelStore.repository
        let firstFolders = try await firstRepo.createFolder(name: "Favorites", colorIndex: 0)
        let secondFolders = try await secondRepo.createFolder(name: "Favorites", colorIndex: 2)
        let firstFolder = try XCTUnwrap(firstFolders.folders.first)
        let secondFolder = try XCTUnwrap(secondFolders.folders.first)
        let first = try await firstRepo.importFile(at: firstSource, originalName: "photo.jpg", kind: .photo, folderID: firstFolder.id)
        let second = try await secondRepo.importFile(at: secondSource, originalName: "photo.jpg", kind: .photo, folderID: secondFolder.id)
        let firstItem = try XCTUnwrap(first.items.first)
        let secondItem = try XCTUnwrap(second.items.first)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(second.items.count, 1)
        XCTAssertNotEqual(firstItem.id, secondItem.id)
        do { _ = try await firstRepo.move(ids: [firstItem.id], to: secondFolder.id); XCTFail("Cross-vault folder accepted") }
        catch { XCTAssertTrue(error is LibraryError) }
        let export = try await firstRepo.export(ids: [firstItem.id, secondItem.id])
        defer { try? FileManager.default.removeItem(at: export) }
        let files = try FileManager.default.contentsOfDirectory(at: export, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), try Data(contentsOf: firstSource))
        _ = try await firstRepo.delete(ids: [firstItem.id, secondItem.id])
        _ = try await firstRepo.deleteFolder(id: firstFolder.id)
        let stillPresent = try await LibraryRepository(root: secondRepo.root).load()
        XCTAssertEqual(stillPresent, second)
        XCTAssertEqual(try Data(contentsOf: secondRepo.mediaURL(secondItem)), try Data(contentsOf: secondSource))
    }
}
