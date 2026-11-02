import Foundation
import XCTest
@testable import patternlock

@MainActor private final class TestFaceID: FaceIDAuthenticating {
    var result: FaceIDResult
    let deferred: Bool
    var honorCancellation = true
    private(set) var requests = 0
    private(set) var cancellations = 0
    private var continuation: CheckedContinuation<FaceIDResult, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?

    init(_ result: FaceIDResult = .authenticated, deferred: Bool = false) { self.result = result; self.deferred = deferred }
    func authenticate(reason: String) async -> FaceIDResult {
        requests += 1
        if deferred {
            return await withCheckedContinuation {
                continuation = $0
                startedWaiter?.resume(); startedWaiter = nil
            }
        }
        return result
    }
    func waitUntilStarted() async {
        if requests > 0 { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func finish(_ result: FaceIDResult) { continuation?.resume(returning: result); continuation = nil }
    func cancel() {
        cancellations += 1
        if honorCancellation { finish(.interrupted) }
    }
}

@MainActor final class FaceIDAccessTests: XCTestCase {
    private let privatePattern = [0, 1, 2, 7, 12]
    private let dummyPattern = [4, 9, 14, 19, 24]
    private let thirdPattern = [0, 5, 10, 15, 20]

    private struct Fixture {
        let auth: PatternAuthenticator
        let storage: MemoryPatternStorage
        let real: Vault
        let dummy: Vault
        let directory: URL
    }

    private func fixture(enabled: Bool = true) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FaceIDTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storage = MemoryPatternStorage()
        let auth = PatternAuthenticator(storage: storage, directory: directory)
        let real = try await auth.register(privatePattern)
        let dummy = try await auth.createVault(name: "Everyday", pattern: dummyPattern)
        if enabled {
            try await auth.setAccessSettings(vaultID: real.id, requireFaceID: true, dummyVaultID: dummy.id,
                currentPattern: privatePattern, dummyPattern: dummyPattern, faceID: TestFaceID())
        }
        return Fixture(auth: auth, storage: storage, real: real, dummy: dummy, directory: directory)
    }

    private func challenge(_ auth: PatternAuthenticator) async throws -> FaceIDChallenge {
        let result = try await auth.verify(privatePattern)
        guard case .requiresFaceID(let challenge) = result else { throw VaultAccessError.changed }
        return challenge
    }

    func testExistingVaultWithoutOptInStillOpensWithPatternOnly() async throws {
        let f = try await fixture(enabled: false)
        let bio = TestFaceID(.failed)
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate(); await lock.submit(privatePattern)
        XCTAssertEqual(lock.unlockedVault, f.real)
        XCTAssertEqual(bio.requests, 0)
        XCTAssertFalse(lock.isDummySession)
    }

    func testProtectedLibraryRemainsHiddenUntilFaceIDSucceeds() async throws {
        let f = try await fixture()
        let bio = TestFaceID(deferred: true)
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate()
        let operation = Task { await lock.submit(privatePattern) }
        await bio.waitUntilStarted()
        XCTAssertEqual(lock.stage, .faceID)
        XCTAssertNil(lock.unlockedVault)
        bio.finish(.authenticated)
        await operation.value
        XCTAssertEqual(lock.unlockedVault, f.real)
        XCTAssertFalse(lock.isDummySession)
        XCTAssertEqual(bio.requests, 1)
    }

    func testFailedFaceIDShowsDuressMarkedDummyWithoutAnyDuressSideEffects() async throws {
        let f = try await fixture()
        let other = try await f.auth.createVault(name: "Other", pattern: thirdPattern)
        try await f.auth.setDuressVault(vaultID: f.dummy.id, enabled: true, currentPattern: dummyPattern)
        let original = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(f.storage.read()))
        let bio = TestFaceID(.failed)
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate(); await lock.submit(privatePattern)
        XCTAssertEqual(lock.unlockedVault, f.dummy)
        XCTAssertTrue(lock.isDummySession)
        lock.beginNewVault()
        XCTAssertEqual(lock.stage, .unlocked)
        XCTAssertFalse(lock.isCreatingVault)
        let after = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(f.storage.read()))
        XCTAssertEqual(after.vaults.count, 3)
        XCTAssertEqual(after.backupsDisabled, original.backupsDisabled)
        XCTAssertEqual(after.sharingEpoch, original.sharingEpoch)
        XCTAssertEqual(after.revokedVaultIDs, original.revokedVaultIDs)
        XCTAssertTrue(after.vaults.allSatisfy { $0.pendingRecoveryPhrase == nil })
        XCTAssertTrue(f.auth.accessIsAllowed(to: f.real.id))
        XCTAssertTrue(f.auth.accessIsAllowed(to: other.id))
        XCTAssertFalse(f.auth.security.backupsDisabled)
    }

    func testDummyWithItsOwnFaceIDDoesNotRecursivelyAuthenticate() async throws {
        let f = try await fixture()
        try await f.auth.setAccessSettings(vaultID: f.dummy.id, requireFaceID: true, dummyVaultID: f.real.id,
            currentPattern: dummyPattern, dummyPattern: privatePattern, faceID: TestFaceID())
        let bio = TestFaceID(.failed)
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate(); await lock.submit(privatePattern)
        XCTAssertEqual(lock.unlockedVault, f.dummy)
        XCTAssertEqual(bio.requests, 1)
        XCTAssertTrue(lock.isDummySession)
    }

    func testWrongPatternNeverPromptsFaceIDOrOpensDummy() async throws {
        let f = try await fixture()
        let bio = TestFaceID(.failed)
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate(); await lock.submit(thirdPattern)
        XCTAssertEqual(lock.stage, .locked)
        XCTAssertNil(lock.unlockedVault)
        XCTAssertEqual(bio.requests, 0)
    }

    func testSystemPromptInactivityDoesNotCancelTheSecondFactor() async throws {
        let f = try await fixture()
        let bio = TestFaceID(deferred: true)
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate()
        let operation = Task { await lock.submit(privatePattern) }
        await bio.waitUntilStarted()
        lock.becameInactive()
        bio.finish(.authenticated)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(lock.unlockedVault)
        XCTAssertEqual(lock.stage, .faceID)
        await lock.activate()
        await operation.value
        XCTAssertEqual(lock.unlockedVault, f.real)
    }

    func testLateFaceIDSuccessCannotUnlockAfterBackground() async throws {
        let f = try await fixture()
        let bio = TestFaceID(deferred: true)
        bio.honorCancellation = false
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate()
        let operation = Task { await lock.submit(privatePattern) }
        await bio.waitUntilStarted()
        lock.enteredBackground()
        bio.finish(.authenticated)
        await operation.value
        XCTAssertNil(lock.unlockedVault)
        XCTAssertGreaterThan(bio.cancellations, 0)
        await lock.activate()
        XCTAssertEqual(lock.stage, .locked)
    }

    func testSystemInterruptionStaysLockedInsteadOfOpeningDummy() async throws {
        let f = try await fixture()
        let lock = PatternLockStore(authenticator: f.auth, faceID: TestFaceID(.interrupted))
        await lock.activate(); await lock.submit(privatePattern)
        XCTAssertEqual(lock.stage, .locked)
        XCTAssertNil(lock.unlockedVault)
        XCTAssertFalse(f.auth.security.backupsDisabled)
    }

    func testDeletingDummyNeverDisablesFaceIDOrExposesProtectedVaultOnFailure() async throws {
        let f = try await fixture()
        try await f.auth.deleteVault(vaultID: f.dummy.id, currentPattern: dummyPattern, directory: f.directory)
        let settings = try await f.auth.settings(for: f.real.id)
        XCTAssertEqual(settings.requiresFaceID, true)
        XCTAssertNil(settings.dummyVaultID)
        let lock = PatternLockStore(authenticator: f.auth, faceID: TestFaceID(.failed))
        await lock.activate(); await lock.submit(privatePattern)
        XCTAssertNil(lock.unlockedVault)
        XCTAssertEqual(lock.stage, .locked)
        let token = try await challenge(f.auth)
        let success = try await f.auth.completeFaceID(token, result: .authenticated)
        XCTAssertEqual(success, .accepted(f.real))
    }

    func testSettingsRequireBothPatternsAndSuccessfulFaceID() async throws {
        let f = try await fixture(enabled: false)
        do {
            try await f.auth.setAccessSettings(vaultID: f.real.id, requireFaceID: true, dummyVaultID: f.dummy.id,
                currentPattern: privatePattern, dummyPattern: thirdPattern, faceID: TestFaceID())
            XCTFail("Dummy selected without its pattern")
        } catch {}
        do {
            try await f.auth.setAccessSettings(vaultID: f.real.id, requireFaceID: true, dummyVaultID: f.dummy.id,
                currentPattern: thirdPattern, dummyPattern: dummyPattern, faceID: TestFaceID())
            XCTFail("Settings changed without the current pattern")
        } catch {}
        do {
            try await f.auth.setAccessSettings(vaultID: f.real.id, requireFaceID: true, dummyVaultID: f.dummy.id,
                currentPattern: privatePattern, dummyPattern: dummyPattern, faceID: TestFaceID(.failed))
            XCTFail("Face ID enabled without proving availability")
        } catch {}
        let saved = try await f.auth.settings(for: f.real.id)
        XCTAssertNotEqual(saved.requiresFaceID, true)
        XCTAssertNil(saved.dummyVaultID)
    }

    func testDuressWithDeletedDummyCannotBypassFaceID() async throws {
        let f = try await fixture()
        let other = try await f.auth.createVault(name: "Other", pattern: thirdPattern)
        try await f.auth.setDuressVault(vaultID: f.real.id, enabled: true, currentPattern: privatePattern)
        try await f.auth.deleteVault(vaultID: f.dummy.id, currentPattern: dummyPattern, directory: f.directory)
        let bio = TestFaceID(.failed)
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate(); await lock.submit(privatePattern)
        XCTAssertNil(lock.unlockedVault)
        XCTAssertEqual(lock.stage, .locked)
        XCTAssertFalse(f.auth.security.backupsDisabled)
        XCTAssertTrue(f.auth.accessIsAllowed(to: other.id))

        bio.result = .authenticated
        await lock.submit(privatePattern)
        XCTAssertEqual(lock.unlockedVault, f.real)
        XCTAssertEqual(bio.requests, 2)
        XCTAssertTrue(f.auth.security.backupsDisabled)
        XCTAssertFalse(f.auth.accessIsAllowed(to: other.id))
    }

    func testCancelledChallengeCannotOpenEitherVault() async throws {
        let f = try await fixture()
        let token = try await challenge(f.auth)
        await f.auth.cancelFaceID(token)
        do { _ = try await f.auth.completeFaceID(token, result: .authenticated); XCTFail("Cancelled challenge accepted") } catch {}
    }

    func testRemovingFaceIDRequiresSuccessfulFaceIDAndPersists() async throws {
        let f = try await fixture()
        do {
            try await f.auth.setAccessSettings(vaultID: f.real.id, requireFaceID: false, dummyVaultID: f.dummy.id,
                currentPattern: privatePattern, dummyPattern: nil, faceID: TestFaceID(.failed))
            XCTFail("Face ID disabled with only a pattern")
        } catch {}
        let before = try await f.auth.settings(for: f.real.id)
        XCTAssertEqual(before.requiresFaceID, true)
        try await f.auth.setAccessSettings(vaultID: f.real.id, requireFaceID: false, dummyVaultID: f.dummy.id,
            currentPattern: privatePattern, dummyPattern: nil, faceID: TestFaceID())
        let restarted = PatternAuthenticator(storage: f.storage, directory: f.directory)
        let result = try await restarted.verify(privatePattern)
        XCTAssertEqual(result, .accepted(f.real))
    }

    func testSettingsSurviveRelaunchAndChallengesCannotBeReused() async throws {
        let f = try await fixture()
        let restarted = PatternAuthenticator(storage: f.storage, directory: f.directory)
        let token = try await challenge(restarted)
        let result = try await restarted.completeFaceID(token, result: .failed)
        XCTAssertEqual(result, .dummy(f.dummy))
        do { _ = try await restarted.completeFaceID(token, result: .authenticated); XCTFail("Replayed challenge accepted") } catch {}
        let fresh = try await challenge(restarted)
        try await restarted.changePattern(vaultID: f.real.id, current: privatePattern, replacement: thirdPattern)
        do { _ = try await restarted.completeFaceID(fresh, result: .authenticated); XCTFail("Old pattern challenge accepted") } catch {}
    }

    func testExplicitDuressUsesSameDummyAndPerformsExistingDuressActions() async throws {
        let f = try await fixture()
        let other = try await f.auth.createVault(name: "Other", pattern: thirdPattern)
        try await f.auth.setDuressVault(vaultID: f.real.id, enabled: true, currentPattern: privatePattern)
        let bio = TestFaceID(.failed)
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate(); await lock.submit(privatePattern)
        XCTAssertEqual(lock.unlockedVault, f.dummy)
        XCTAssertTrue(lock.isDummySession)
        XCTAssertEqual(bio.requests, 0, "A duress pattern must not wait for Face ID")
        XCTAssertTrue(f.auth.security.backupsDisabled)
        XCTAssertFalse(f.auth.accessIsAllowed(to: f.real.id))
        XCTAssertFalse(f.auth.accessIsAllowed(to: other.id))
        let survivor = try await f.auth.settings(for: f.dummy.id)
        XCTAssertNotNil(survivor.pendingRecoveryPhrase)
    }

    func testDummySelectionAloneDoesNotArmDuressOrEnableFaceID() async throws {
        let f = try await fixture(enabled: false)
        let bio = TestFaceID(.failed)
        try await f.auth.setAccessSettings(vaultID: f.real.id, requireFaceID: false, dummyVaultID: f.dummy.id,
            currentPattern: privatePattern, dummyPattern: dummyPattern, faceID: bio)
        XCTAssertEqual(bio.requests, 0)
        let result = try await f.auth.verify(privatePattern)
        XCTAssertEqual(result, .accepted(f.real))
        let saved = try await f.auth.settings(for: f.real.id)
        XCTAssertNotEqual(saved.isDuressVault, true)
        XCTAssertFalse(f.auth.security.backupsDisabled)
    }

    func testRevocationWhileFaceIDIsRunningPreventsAnyOpen() async throws {
        let f = try await fixture()
        let bio = TestFaceID(deferred: true)
        bio.honorCancellation = false
        let lock = PatternLockStore(authenticator: f.auth, faceID: bio)
        await lock.activate()
        let operation = Task { await lock.submit(privatePattern) }
        await bio.waitUntilStarted()
        XCTAssertTrue(lock.revokeAccess(to: f.real.id))
        bio.finish(.authenticated)
        await operation.value
        XCTAssertNil(lock.unlockedVault)
    }
}
