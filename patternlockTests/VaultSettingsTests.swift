import Foundation
import XCTest
@testable import patternlock

final class VaultSettingsTests: XCTestCase {
    private let pattern = [0, 1, 2, 7, 12]
    private let otherPattern = [4, 9, 14, 19, 24]
    private let replacement = [0, 5, 10, 15, 20]
    private let phrase = "these eight chosen words make a sufficiently long recovery phrase"

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "SettingsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testRenameAndChangePatternPreserveVaultAndRejectOtherVaultPattern() async throws {
        let auth = PatternAuthenticator(storage: MemoryPatternStorage())
        let vault = try await auth.register(pattern)
        let other = try await auth.createVault(name: "Travel", pattern: otherPattern)
        let renamed = try await auth.renameVault(vault.id, name: "  Private  ")
        XCTAssertEqual(renamed.id, vault.id)
        XCTAssertEqual(renamed.name, "Private")
        do { _ = try await auth.renameVault(vault.id, name: "travel"); XCTFail("Duplicate name accepted") } catch {}
        do { try await auth.changePattern(vaultID: vault.id, current: otherPattern, replacement: replacement); XCTFail("Wrong current pattern accepted") } catch {}
        do { try await auth.changePattern(vaultID: vault.id, current: pattern, replacement: otherPattern); XCTFail("Other vault's pattern reused") } catch {}
        try await auth.changePattern(vaultID: vault.id, current: pattern, replacement: replacement)
        let old = try await auth.verify(pattern)
        let new = try await auth.verify(replacement)
        let untouched = try await auth.verify(otherPattern)
        XCTAssertEqual(old, .rejected(retryAfter: nil))
        XCTAssertEqual(new, .accepted(renamed))
        XCTAssertEqual(untouched, .accepted(other))
    }

    func testRecoveryRotationPersistsAndResetsOnlyMatchingVault() async throws {
        let storage = MemoryPatternStorage()
        let auth = PatternAuthenticator(storage: storage)
        let vault = try await auth.register(pattern)
        let other = try await auth.createVault(name: "Travel", pattern: otherPattern)
        try await auth.setRecoveryPhrase(vaultID: vault.id, phrase: phrase, currentPattern: pattern)
        let raw = String(decoding: try XCTUnwrap(storage.read()), as: UTF8.self)
        XCTAssertFalse(raw.contains(phrase))
        do { try await auth.setRecoveryPhrase(vaultID: other.id, phrase: phrase, currentPattern: otherPattern); XCTFail("Ambiguous recovery phrase accepted") } catch {}
        let fresh = PatternAuthenticator(storage: storage)
        let recovered = try await fresh.recover(phrase: phrase.uppercased().replacingOccurrences(of: " ", with: "  "), newPattern: replacement)
        XCTAssertEqual(recovered, vault)
        let result = try await fresh.verify(replacement)
        XCTAssertEqual(result, .accepted(vault))
        let nextPhrase = try RecoveryPhrase.generate()
        try await fresh.setRecoveryPhrase(vaultID: vault.id, phrase: nextPhrase, currentPattern: replacement)
        do { try await fresh.validateRecoveryPhrase(vaultID: vault.id, phrase: phrase); XCTFail("Old phrase remained active") } catch {}
        try await fresh.validateRecoveryPhrase(vaultID: vault.id, phrase: nextPhrase)
        let otherResult = try await fresh.verify(otherPattern)
        XCTAssertEqual(otherResult, .accepted(other))
    }

    func testRecoveryFailuresSharePersistentCooldown() async throws {
        let storage = MemoryPatternStorage()
        let auth = PatternAuthenticator(storage: storage)
        _ = try await auth.register(pattern)
        try await auth.setRecoveryPhrase(vaultID: Vault.personal.id, phrase: phrase, currentPattern: pattern)
        for _ in 0..<5 {
            do { _ = try await auth.recover(phrase: "incorrect recovery words", newPattern: replacement); XCTFail("Incorrect recovery accepted") } catch {}
        }
        let fresh = PatternAuthenticator(storage: storage)
        let status = try await fresh.status()
        XCTAssertNotNil(status.retryAfter)
        do { _ = try await fresh.recover(phrase: phrase, newPattern: replacement); XCTFail("Cooldown bypassed") } catch {}
    }

    func testGeneratedPhrasesHaveTwentyRandomWordsAndWeakCustomPhrasesAreRejected() throws {
        let first = try RecoveryPhrase.generate()
        let second = try RecoveryPhrase.generate()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.split(separator: " ").count, 20)
        XCTAssertEqual(Set(RecoveryPhrase.words).count, 128)
        try RecoveryPhrase.validate(first)
        XCTAssertThrowsError(try RecoveryPhrase.validate("short phrase"))
        let credential = try RecoveryPhrase.credential(for: first)
        XCTAssertTrue(try RecoveryPhrase.matches(first, credential: credential))
        XCTAssertFalse(try RecoveryPhrase.matches(second, credential: credential))
    }

    func testDeleteRemovesOnlySelectedVaultAndLastVaultCanBeRecreated() async throws {
        let directory = try workspace()
        let auth = PatternAuthenticator(storage: MemoryPatternStorage())
        let vault = try await auth.register(pattern)
        let other = try await auth.createVault(name: "Everyday", pattern: otherPattern)
        _ = try await LibraryRepository(root: vault.root(in: directory)).createFolder(name: "Private", colorIndex: 0)
        _ = try await LibraryRepository(root: other.root(in: directory)).createFolder(name: "Ordinary", colorIndex: 0)
        do { try await auth.deleteVault(vaultID: vault.id, currentPattern: otherPattern, directory: directory); XCTFail("Wrong pattern deleted a vault") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.root(in: directory).path))
        try await auth.deleteVault(vaultID: other.id, currentPattern: otherPattern, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.root(in: directory).path))
        let owner = try await auth.settings(for: vault.id)
        XCTAssertNil(owner.duressVaultID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.root(in: directory).path))
        try await auth.deleteVault(vaultID: vault.id, currentPattern: pattern, directory: directory)
        let empty = try await auth.status()
        XCTAssertFalse(empty.isRegistered)
        _ = try await auth.register(replacement)
        let fresh = try await LibraryRepository(root: vault.root(in: directory)).load()
        XCTAssertTrue(fresh.folders.isEmpty)
    }

    func testDeletionRollsBackIfKeychainWriteFails() async throws {
        let directory = try workspace()
        let storage = FailingSettingsStorage()
        let auth = PatternAuthenticator(storage: storage)
        let vault = try await auth.register(pattern)
        let repository = LibraryRepository(root: vault.root(in: directory))
        let before = try await repository.createFolder(name: "Keep me", colorIndex: 1)
        storage.failUpdates = true
        do { try await auth.deleteVault(vaultID: vault.id, currentPattern: pattern, directory: directory); XCTFail("Failure ignored") } catch {}
        let reloaded = try await LibraryRepository(root: vault.root(in: directory)).load()
        XCTAssertEqual(reloaded, before)
        storage.failUpdates = false
        let unlocked = try await auth.verify(pattern)
        XCTAssertEqual(unlocked, .accepted(vault))
    }

    func testInterruptedVaultDeletionRestoresRegisteredVaultButPurgesDeletedVault() async throws {
        let directory = try workspace()
        let auth = PatternAuthenticator(storage: MemoryPatternStorage())
        let vault = try await auth.register(pattern)
        let root = vault.root(in: directory)
        let before = try await LibraryRepository(root: root).createFolder(name: "Recovered", colorIndex: 0)
        let staged = directory.appending(path: "DeletingVault-" + vault.id)
        try FileManager.default.moveItem(at: root, to: staged)
        try await auth.cleanDeletedVaults(in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        let recovered = try await LibraryRepository(root: root).load()
        XCTAssertEqual(recovered, before)
        let orphan = directory.appending(path: "DeletingVault-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try await auth.cleanDeletedVaults(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    @MainActor func testAccessRevocationLocksOnlyAffectedSessionsAndCancelsNewVaultSetup() async throws {
        let auth = PatternAuthenticator(storage: MemoryPatternStorage())
        _ = try await auth.register(pattern)
        let other = try await auth.createVault(name: "Other", pattern: otherPattern)
        let first = PatternLockStore(authenticator: auth)
        let second = PatternLockStore(authenticator: auth)
        await first.activate(); await second.activate()
        await first.submit(pattern); await second.submit(otherPattern)
        first.beginNewVault()
        XCTAssertTrue(first.revokeAccess(to: Vault.personal.id))
        XCTAssertFalse(second.revokeAccess(to: Vault.personal.id))
        first.cancelNewVault()
        XCTAssertNil(first.unlockedVault)
        XCTAssertEqual(second.unlockedVault, other)
    }
}

private final class FailingSettingsStorage: PatternCredentialStorage, @unchecked Sendable {
    private let storage = MemoryPatternStorage()
    var failUpdates = false
    func read() throws -> Data? { try storage.read() }
    func create(_ data: Data) throws { try storage.create(data) }
    func update(_ data: Data) throws {
        if failUpdates { throw PatternCredentialError.inaccessible }
        try storage.update(data)
    }
}
