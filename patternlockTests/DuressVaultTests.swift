import Foundation
import XCTest
@testable import patternlock

final class DuressVaultTests: XCTestCase {
    private let privatePattern = [0, 1, 2, 7, 12]
    private let duressPattern = [4, 9, 14, 19, 24]
    private let thirdPattern = [0, 5, 10, 15, 20]
    private let privatePhrase = "these eight chosen words make a sufficiently long recovery phrase"

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DuressTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testArmingRequiresCurrentPatternAndDoesNotActivateUntilUnlock() async throws {
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), directory: try workspace())
        let first = try await auth.register(privatePattern)
        let second = try await auth.createVault(name: "Everyday", pattern: duressPattern)
        do { try await auth.setDuressVault(vaultID: second.id, enabled: true, currentPattern: privatePattern); XCTFail("Wrong pattern armed duress") } catch {}
        try await auth.setDuressVault(vaultID: second.id, enabled: true, currentPattern: duressPattern)
        let firstSettings = try await auth.settings(for: first.id)
        let secondSettings = try await auth.settings(for: second.id)
        XCTAssertEqual(firstSettings.vault, first)
        XCTAssertEqual(secondSettings.isDuressVault, true)
        XCTAssertNil(secondSettings.recovery)
        XCTAssertFalse(auth.security.backupsDisabled)
        // Confirming a pattern inside settings must not trigger duress.
        try await auth.setDuressVault(vaultID: second.id, enabled: false, currentPattern: duressPattern)
        let ordinary = try await auth.verify(duressPattern)
        let privateUnlock = try await auth.verify(privatePattern)
        XCTAssertEqual(ordinary, .accepted(second))
        XCTAssertEqual(privateUnlock, .accepted(first))
    }

    func testActivationPersistsCredentialRemovalRotationAndBackupPolicyWithoutDeletingMedia() async throws {
        let directory = try workspace()
        let storage = MemoryPatternStorage()
        let security = VaultSecurityState()
        let auth = PatternAuthenticator(storage: storage, security: security, directory: directory)
        let first = try await auth.register(privatePattern)
        let survivor = try await auth.createVault(name: "Everyday", pattern: duressPattern)
        let third = try await auth.createVault(name: "Travel", pattern: thirdPattern)
        try await auth.setRecoveryPhrase(vaultID: first.id, phrase: privatePhrase, currentPattern: privatePattern)
        let oldPhrase = try RecoveryPhrase.generate()
        try await auth.setRecoveryPhrase(vaultID: survivor.id, phrase: oldPhrase, currentPattern: duressPattern)
        let removedRepository = LibraryRepository(root: first.root(in: directory), security: security)
        _ = try await removedRepository.createFolder(name: "Private", colorIndex: 0)
        let survivorRepository = LibraryRepository(root: survivor.root(in: directory), security: security)
        let before = try await survivorRepository.createFolder(name: "Ordinary", colorIndex: 0)
        let privateLease = try security.lease(for: first.id)
        let survivorLease = try security.lease(for: survivor.id)
        try await auth.setDuressVault(vaultID: survivor.id, enabled: true, currentPattern: duressPattern)
        let result = try await auth.verify(duressPattern)
        XCTAssertEqual(result, .accepted(survivor))
        let after = try await survivorRepository.load()
        XCTAssertEqual(after, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.root(in: directory).appending(path: "library.json").path))
        XCTAssertThrowsError(try security.check(privateLease))
        XCTAssertThrowsError(try security.check(survivorLease))
        XCTAssertFalse(auth.accessIsAllowed(to: first.id))
        XCTAssertFalse(auth.accessIsAllowed(to: third.id))
        do { _ = try await removedRepository.load(); XCTFail("Cached repository retained access") } catch {}
        do { _ = try await auth.createVault(name: "Late", pattern: thirdPattern, from: first.id); XCTFail("Revoked session created a vault") } catch {}

        let restarted = PatternAuthenticator(storage: storage, directory: directory)
        let settings = try await restarted.settings(for: survivor.id)
        let newPhrase = try XCTUnwrap(settings.pendingRecoveryPhrase)
        XCTAssertNotEqual(newPhrase, oldPhrase)
        XCTAssertTrue(restarted.security.backupsDisabled)
        XCTAssertFalse(restarted.accessIsAllowed(to: first.id))
        do { _ = try await restarted.settings(for: first.id); XCTFail("Removed credentials retained") } catch {}
        let oldUnlock = try await restarted.verify(privatePattern)
        XCTAssertEqual(oldUnlock, .rejected(retryAfter: nil))
        do { _ = try await restarted.recover(phrase: privatePhrase, newPattern: thirdPattern); XCTFail("Removed recovery still works") } catch {}
        do { try await restarted.validateRecoveryPhrase(vaultID: survivor.id, phrase: oldPhrase); XCTFail("Old survivor phrase works") } catch {}
        try await restarted.validateRecoveryPhrase(vaultID: survivor.id, phrase: newPhrase)
        let shown = try await restarted.pendingRecoveryPhrase(vaultID: survivor.id, currentPattern: duressPattern)
        XCTAssertEqual(shown, newPhrase)
        try await restarted.acknowledgeRecoveryPhrase(vaultID: survivor.id, phrase: newPhrase)
        XCTAssertFalse(String(decoding: try XCTUnwrap(storage.read()), as: UTF8.self).contains(newPhrase))
        try await restarted.validateRecoveryPhrase(vaultID: survivor.id, phrase: newPhrase)

        let freshRepository = LibraryRepository(root: survivor.root(in: directory), security: restarted.security)
        _ = try await freshRepository.load()
        for url in [directory, first.root(in: directory), survivor.root(in: directory)] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
        do {
            _ = try await VaultBackup().create(name: survivor.name, snapshot: before, root: survivor.root(in: directory), phrase: newPhrase, security: restarted.security)
            XCTFail("Backup remained available")
        } catch VaultSettingsError.backupsDisabled {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testEveryDuressUnlockRotatesAgainAndDisablingDoesNotUndoLockdown() async throws {
        let directory = try workspace()
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), directory: directory)
        let survivor = try await auth.register(duressPattern)
        try await auth.setDuressVault(vaultID: survivor.id, enabled: true, currentPattern: duressPattern)
        _ = try await auth.verify(duressPattern)
        let first = try await auth.settings(for: survivor.id)
        let extra = try await auth.createVault(name: "Later", pattern: privatePattern)
        _ = try await auth.verify(duressPattern)
        let second = try await auth.settings(for: survivor.id)
        XCTAssertNotEqual(first.pendingRecoveryPhrase, second.pendingRecoveryPhrase)
        XCTAssertFalse(auth.accessIsAllowed(to: extra.id))
        do { try await auth.acknowledgeRecoveryPhrase(vaultID: survivor.id, phrase: first.pendingRecoveryPhrase!); XCTFail("Stale save cleared the new phrase") } catch {}
        try await auth.setDuressVault(vaultID: survivor.id, enabled: false, currentPattern: duressPattern)
        _ = try await auth.verify(duressPattern)
        let disabled = try await auth.settings(for: survivor.id)
        XCTAssertEqual(second.pendingRecoveryPhrase, disabled.pendingRecoveryPhrase)
        XCTAssertTrue(auth.security.backupsDisabled)
        try await auth.deleteVault(vaultID: survivor.id, currentPattern: duressPattern, directory: directory)
        _ = try await auth.register(thirdPattern)
        let stillDisabled = try await auth.backupsAreDisabled()
        XCTAssertTrue(stillDisabled)
    }

    func testFailedKeychainCommitKeepsEveryCredentialAndPhraseIntact() async throws {
        let storage = DuressFailingStorage()
        let auth = PatternAuthenticator(storage: storage, directory: try workspace())
        let first = try await auth.register(privatePattern)
        let survivor = try await auth.createVault(name: "Everyday", pattern: duressPattern)
        try await auth.setRecoveryPhrase(vaultID: survivor.id, phrase: privatePhrase, currentPattern: duressPattern)
        try await auth.setDuressVault(vaultID: survivor.id, enabled: true, currentPattern: duressPattern)
        let before = try storage.read()
        storage.failUpdates = true
        do { _ = try await auth.verify(duressPattern); XCTFail("Failed lockdown opened the vault") } catch {}
        XCTAssertEqual(try storage.read(), before)
        XCTAssertTrue(auth.accessIsAllowed(to: first.id))
        XCTAssertFalse(auth.security.backupsDisabled)
        storage.failUpdates = false
        try await auth.validateRecoveryPhrase(vaultID: survivor.id, phrase: privatePhrase)
        let result = try await auth.verify(privatePattern)
        XCTAssertEqual(result, .accepted(first))
    }

    func testLegacyDecoyDoesNotBecomeDestructiveWithoutExplicitSetup() async throws {
        let storage = MemoryPatternStorage()
        let auth = PatternAuthenticator(storage: storage, directory: try workspace())
        let first = try await auth.register(privatePattern)
        let second = try await auth.createVault(name: "Everyday", pattern: duressPattern)
        var legacy = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(storage.read()))
        legacy.vaults[0].duressVaultID = second.id
        try storage.update(JSONEncoder().encode(legacy))
        _ = try await auth.verify(duressPattern)
        let retained = try await auth.settings(for: first.id)
        let normal = try await auth.settings(for: second.id)
        XCTAssertNil(retained.duressVaultID)
        XCTAssertNotEqual(normal.isDuressVault, true)
        XCTAssertFalse(auth.security.backupsDisabled)
    }

    func testPreparedRestoreCannotFinishAcrossDuressActivation() async throws {
        let directory = try workspace()
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), directory: directory)
        let survivor = try await auth.register(duressPattern)
        let repo = LibraryRepository(root: survivor.root(in: directory), security: auth.security)
        let snapshot = try await repo.load()
        let backup = VaultBackup()
        let file = try await backup.create(name: survivor.name, snapshot: snapshot, root: repo.root, phrase: privatePhrase, security: auth.security)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let prepared = try await backup.prepareRestore(from: file, phrase: privatePhrase, security: auth.security)
        try await auth.setDuressVault(vaultID: survivor.id, enabled: true, currentPattern: duressPattern)
        _ = try await auth.verify(duressPattern)
        do {
            _ = try await backup.install(prepared, name: "Late restore", pattern: privatePattern, authenticator: auth, directory: directory)
            XCTFail("A restore started before duress retained authorization")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        // Deliberately reopening a saved backup after duress is still supported.
        let reopened = try await backup.prepareRestore(from: file, phrase: privatePhrase, security: auth.security)
        let restored = try await backup.install(reopened, name: "Restored", pattern: privatePattern, authenticator: auth, directory: directory)
        let settings = try await auth.settings(for: restored.id)
        XCTAssertEqual(settings.vault, restored)
        XCTAssertTrue(auth.security.backupsDisabled)
    }

    @MainActor func testUnlockAcceptedBeforeDuressCannotOpenAfterRevocation() async throws {
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), directory: try workspace())
        _ = try await auth.register(privatePattern)
        let survivor = try await auth.createVault(name: "Everyday", pattern: duressPattern)
        try await auth.setDuressVault(vaultID: survivor.id, enabled: true, currentPattern: duressPattern)
        let delayed = DelayedDuressAuthenticator(base: auth)
        let lock = PatternLockStore(authenticator: delayed)
        await lock.activate()
        let operation = Task { await lock.submit(privatePattern) }
        await delayed.waitForAcceptedResult()
        _ = try await auth.verify(duressPattern)
        await delayed.release()
        await operation.value
        XCTAssertNil(lock.unlockedVault)
        XCTAssertNotEqual(lock.stage, .unlocked)
    }

    @MainActor func testActiveShareFilesAndRevokedStoreAreCleared() async throws {
        let directory = try workspace()
        let security = VaultSecurityState()
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), security: security, directory: directory)
        let first = try await auth.register(privatePattern)
        let survivor = try await auth.createVault(name: "Everyday", pattern: duressPattern)
        let libraries = VaultLibraries(directory: directory, security: security)
        let firstStore = libraries.store(for: first)
        let survivingStore = libraries.store(for: survivor)
        await firstStore.load(); await survivingStore.load()
        _ = await firstStore.saveFolder(nil, name: "Private", colorIndex: 0)
        // An empty selection result still creates a real temporary share directory.
        await survivingStore.export([UUID()])
        let share = try XCTUnwrap(survivingStore.exportSession)
        try await auth.setDuressVault(vaultID: survivor.id, enabled: true, currentPattern: duressPattern)
        _ = try await auth.verify(duressPattern)
        libraries.applyDuress(DuressActivation(revokedVaultIDs: [first.id]))
        XCTAssertNil(survivingStore.exportSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.directory.path))
        XCTAssertTrue(firstStore.snapshot.folders.isEmpty)
        await firstStore.load()
        XCTAssertFalse(firstStore.isLoaded)
        XCTAssertTrue(survivingStore.isLoaded)
    }
}

private final class DuressFailingStorage: PatternCredentialStorage, @unchecked Sendable {
    private let storage = MemoryPatternStorage()
    var failUpdates = false
    func read() throws -> Data? { try storage.read() }
    func create(_ data: Data) throws { try storage.create(data) }
    func update(_ data: Data) throws {
        if failUpdates { throw PatternCredentialError.inaccessible }
        try storage.update(data)
    }
}

private actor DelayedDuressAuthenticator: PatternAuthenticating {
    nonisolated let base: PatternAuthenticator
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var accepted = false
    init(base: PatternAuthenticator) { self.base = base }
    nonisolated func accessIsAllowed(to vaultID: String) -> Bool { base.accessIsAllowed(to: vaultID) }
    func status() async throws -> PatternLockStatus { try await base.status() }
    func register(_ nodes: [Int]) async throws -> Vault { try await base.register(nodes) }
    func createVault(name: String, pattern: [Int]) async throws -> Vault { try await base.createVault(name: name, pattern: pattern) }
    func verify(_ nodes: [Int], now: Date) async throws -> PatternVerification {
        let value = try await base.verify(nodes, now: now)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            accepted = true; waiter?.resume(); waiter = nil
        }
        return value
    }
    func waitForAcceptedResult() async {
        if accepted { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
