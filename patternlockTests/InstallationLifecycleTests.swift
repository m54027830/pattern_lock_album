import Foundation
import Security
import XCTest
@testable import patternlock

final class InstallationLifecycleTests: XCTestCase {
    private let pattern = [0, 1, 2, 7, 12]
    private let phrase = "these eight chosen words make a sufficiently long recovery phrase"

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "InstallationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func authenticator(_ storage: any ResettablePatternCredentialStorage, at root: URL) -> PatternAuthenticator {
        PatternAuthenticator(storage: InstallationCredentialStorage(storage: storage, applicationSupport: root), directory: root.appending(path: "Vaults"))
    }

    @MainActor func testReinstallStartsOnboardingAndCannotReusePatternsRecoveryOrSettings() async throws {
        let root = try workspace()
        let storage = MemoryPatternStorage()
        let auth = authenticator(storage, at: root)
        let vault = try await auth.registerFirstVault(name: "Private name", pattern: [0, 1, 2, 5], gridSize: 3, recoveryPhrase: phrase)
        let repository = LibraryRepository(root: vault.root(in: root.appending(path: "Vaults")))
        _ = try await repository.createFolder(name: "Local only", colorIndex: 1)
        try await auth.setDuressVault(vaultID: vault.id, enabled: true, currentPattern: [0, 1, 2, 5])
        _ = try await auth.verify([0, 1, 2, 5])
        let encrypted = try XCTUnwrap(storage.read())
        XCTAssertNil(encrypted.range(of: Data("Private name".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(VaultRegistry.self, from: encrypted))

        // Delete App removes the sandbox while Keychain may survive.
        try FileManager.default.removeItem(at: root)
        let reinstalled = authenticator(storage, at: root)
        let lock = PatternLockStore(authenticator: reinstalled)
        await lock.activate()
        XCTAssertEqual(lock.stage, .onboarding)
        XCTAssertEqual(lock.gridSize, 5)
        XCTAssertNil(try storage.read())
        XCTAssertFalse(reinstalled.security.backupsDisabled)
        do { _ = try await reinstalled.recover(phrase: phrase, newPattern: pattern); XCTFail("Old recovery survived reinstall") } catch {}
        let fresh = try await reinstalled.registerFirstVault(name: "Fresh", pattern: pattern, gridSize: 5, recoveryPhrase: phrase)
        let empty = try await LibraryRepository(root: fresh.root(in: root.appending(path: "Vaults"))).load()
        XCTAssertTrue(empty.folders.isEmpty)
        XCTAssertTrue(empty.items.isEmpty)
        let settings = try await reinstalled.settings(for: fresh.id)
        XCTAssertNotEqual(settings.isDuressVault, true)
        XCTAssertNil(settings.requiresFaceID)
        XCTAssertNil(settings.dummyVaultID)
    }

    func testRelaunchAndAppUpdatePreserveCredentialsMediaAndInstallationKey() async throws {
        let root = try workspace()
        let storage = MemoryPatternStorage()
        let auth = authenticator(storage, at: root)
        let vault = try await auth.registerFirstVault(name: "Keep", pattern: pattern, gridSize: 5, recoveryPhrase: phrase)
        let repository = LibraryRepository(root: vault.root(in: root.appending(path: "Vaults")))
        let before = try await repository.createFolder(name: "Keep", colorIndex: 2)
        let keyURL = root.appending(path: "Installation/credential-key")
        let key = try Data(contentsOf: keyURL)
        let restarted = authenticator(storage, at: root)
        let result = try await restarted.verify(pattern)
        XCTAssertEqual(result, .accepted(vault))
        try await restarted.validateRecoveryPhrase(vaultID: vault.id, phrase: phrase)
        let after = try await LibraryRepository(root: repository.root).load()
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: keyURL), key)
        for url in [keyURL, root.appending(path: "Installation"), root.appending(path: "Vaults"), repository.root] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
    }

    func testLegacyUpgradePreservesLocalVaultButOrphanedKeychainStartsFresh() async throws {
        let root = try workspace()
        let storage = MemoryPatternStorage()
        let old = PatternAuthenticator(storage: storage)
        let vault = try await old.registerFirstVault(name: "Existing", pattern: pattern, gridSize: 5, recoveryPhrase: phrase)
        let directory = vault.root(in: root.appending(path: "Vaults"))
        let before = try await LibraryRepository(root: directory).createFolder(name: "Existing", colorIndex: 0)
        let legacyData = try XCTUnwrap(storage.read())
        var included = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = false
        try included.setResourceValues(values)
        let upgraded = authenticator(storage, at: root)
        let result = try await upgraded.verify(pattern)
        XCTAssertEqual(result, .accepted(vault))
        let after = try await LibraryRepository(root: directory).load()
        XCTAssertEqual(before, after)
        XCTAssertNotEqual(try storage.read(), legacyData)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        let reinstallRoot = try workspace()
        let leftover = MemoryPatternStorage(data: legacyData)
        let clean = try await authenticator(leftover, at: reinstallRoot).status()
        XCTAssertFalse(clean.isRegistered)
        XCTAssertNil(try leftover.read())
    }

    func testMissingInstallationKeyDiscardsRestoredLocalFilesInsteadOfRevivingCredentials() async throws {
        let root = try workspace()
        let storage = MemoryPatternStorage()
        let auth = authenticator(storage, at: root)
        let vault = try await auth.register(pattern)
        let directory = vault.root(in: root.appending(path: "Vaults"))
        _ = try await LibraryRepository(root: directory).createFolder(name: "Old device copy", colorIndex: 0)
        try FileManager.default.removeItem(at: root.appending(path: "Installation"))
        let status = try await authenticator(storage, at: root).status()
        XCTAssertFalse(status.isRegistered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(try storage.read())
    }

    func testKeychainFailureDoesNotWriteInstallationKeyOrAcceptStaleCredentials() async throws {
        let root = try workspace()
        let storage = FailingInstallationStorage()
        let old = PatternAuthenticator(storage: storage)
        _ = try await old.register(pattern)
        let before = try storage.read()
        storage.failRemoval = true
        let clean = authenticator(storage, at: root)
        do { _ = try await clean.status(); XCTFail("Failed reset accepted old credentials") } catch {}
        XCTAssertEqual(try storage.read(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Installation/credential-key").path))
        storage.failRemoval = false
        let status = try await clean.status()
        XCTAssertFalse(status.isRegistered)
    }

    func testInterruptedLegacyEncryptionCanRetryWithoutLosingVault() async throws {
        let root = try workspace()
        let storage = FailingInstallationStorage()
        let old = PatternAuthenticator(storage: storage)
        let vault = try await old.register(pattern)
        _ = try await LibraryRepository(root: vault.root(in: root.appending(path: "Vaults"))).load()
        let before = try storage.read()
        storage.failUpdate = true
        let upgraded = authenticator(storage, at: root)
        do { _ = try await upgraded.status(); XCTFail("Failed migration ignored") } catch {}
        XCTAssertEqual(try storage.read(), before)
        storage.failUpdate = false
        let result = try await upgraded.verify(pattern)
        XCTAssertEqual(result, .accepted(vault))
    }

    func testCorruptInstallationKeyOrEncryptedRecordFailsClosedWithoutReset() async throws {
        let root = try workspace()
        let storage = MemoryPatternStorage()
        _ = try await authenticator(storage, at: root).register(pattern)
        let before = try storage.read()
        let keyURL = root.appending(path: "Installation/credential-key")
        let correctKey = try Data(contentsOf: keyURL)
        for key in [Data([1, 2]), Data(repeating: 7, count: 32)] {
            try key.write(to: keyURL)
            do { _ = try await authenticator(storage, at: root).status(); XCTFail("Corrupt key accepted or reset") } catch {}
            XCTAssertEqual(try storage.read(), before)
        }
        try correctKey.write(to: keyURL)
        var corrupt = try XCTUnwrap(before); corrupt[corrupt.count - 1] ^= 1
        try storage.update(corrupt)
        do { _ = try await authenticator(storage, at: root).status(); XCTFail("Tampered record accepted") } catch {}
        XCTAssertEqual(try storage.read(), corrupt)
    }

    func testOnlyExplicitEncryptedBackupRestoreReturnsDataAfterReinstall() async throws {
        let root = try workspace()
        let storage = MemoryPatternStorage()
        let auth = authenticator(storage, at: root)
        let vault = try await auth.registerFirstVault(name: "Original", pattern: pattern, gridSize: 5, recoveryPhrase: phrase)
        let repository = LibraryRepository(root: vault.root(in: root.appending(path: "Vaults")))
        let snapshot = try await repository.createFolder(name: "From iCloud archive", colorIndex: 1)
        let backup = VaultBackup()
        let archive = try await backup.create(name: vault.name, snapshot: snapshot, root: repository.root, phrase: phrase, security: auth.security)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: root)
        let fresh = authenticator(storage, at: root)
        let status = try await fresh.status()
        XCTAssertFalse(status.isRegistered)
        let prepared = try await backup.prepareRestore(from: archive, phrase: phrase, security: fresh.security)
        let restored = try await backup.install(prepared, name: "Restored", pattern: pattern, authenticator: fresh, directory: root.appending(path: "Vaults"))
        let contents = try await LibraryRepository(root: restored.root(in: root.appending(path: "Vaults"))).load()
        XCTAssertEqual(contents, snapshot)
        let result = try await fresh.verify(pattern)
        XCTAssertEqual(result, .accepted(restored))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path), "Restoring must not delete the cloud source")
    }

    func testRealKeychainRecordIsScopedAndClearedWhenContainerDisappears() async throws {
        let service = "jp.gm.patternlock.installation-tests." + UUID().uuidString
        let raw = KeychainPatternStorage(service: service)
        defer { try? raw.remove() }
        let root = try workspace()
        _ = try await authenticator(raw, at: root).register(pattern)
        XCTAssertNotNil(try raw.read())
        try FileManager.default.removeItem(at: root)
        let status = try await authenticator(raw, at: root).status()
        XCTAssertFalse(status.isRegistered)
        XCTAssertNil(try raw.read())
    }
}

private final class FailingInstallationStorage: ResettablePatternCredentialStorage, @unchecked Sendable {
    private let storage = MemoryPatternStorage()
    var failRemoval = false
    var failUpdate = false
    func read() throws -> Data? { try storage.read() }
    func create(_ data: Data) throws { try storage.create(data) }
    func update(_ data: Data) throws {
        if failUpdate { throw PatternCredentialError.inaccessible }
        try storage.update(data)
    }
    func remove() throws {
        if failRemoval { throw PatternCredentialError.inaccessible }
        try storage.remove()
    }
}
