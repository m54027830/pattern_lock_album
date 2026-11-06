import Foundation
import XCTest
@testable import patternlock

@MainActor private final class GridFaceID: FaceIDAuthenticating {
    var result = FaceIDResult.authenticated
    var requests = 0
    var duringAuthentication: (() async throws -> Void)?
    func authenticate(reason: String) async -> FaceIDResult {
        requests += 1
        do { try await duringAuthentication?() } catch { return .interrupted }
        return result
    }
    func cancel() {}
}

private final class GridStorage: PatternCredentialStorage, @unchecked Sendable {
    private let storage = MemoryPatternStorage()
    var failWrite = false
    func read() throws -> Data? { try storage.read() }
    func create(_ data: Data) throws { if failWrite { throw PatternCredentialError.inaccessible }; try storage.create(data) }
    func update(_ data: Data) throws { if failWrite { throw PatternCredentialError.inaccessible }; try storage.update(data) }
}

@MainActor final class OnboardingGridTests: XCTestCase {
    private let oldA = [0, 1, 2, 7, 12]
    private let oldB = [4, 9, 14, 19, 24]
    private let newA = [0, 1, 4, 7]
    private let newB = [2, 5, 8, 7]
    private let phrase = "acorn amber anchor apple apron arrow atlas autumn"

    private struct Fixture {
        let auth: PatternAuthenticator
        let storage: GridStorage
        let a: Vault
        let b: Vault
        let root: URL
    }
    private func fixture(protected: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "GridTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = GridStorage(), auth = PatternAuthenticator(storage: storage, directory: root)
        let a = try await auth.register(oldA), b = try await auth.createVault(name: "Travel", pattern: oldB)
        try await auth.setRecoveryPhrase(vaultID: a.id, phrase: phrase, currentPattern: oldA)
        if protected {
            try await auth.setAccessSettings(vaultID: a.id, requireFaceID: true, dummyVaultID: b.id,
                currentPattern: oldA, dummyPattern: oldB, faceID: GridFaceID())
        }
        return Fixture(auth: auth, storage: storage, a: a, b: b, root: root)
    }
    private func replacements(_ f: Fixture) -> [VaultPatternReplacement] {
        [.init(vaultID: f.a.id, current: oldA, replacement: newA, confirmation: newA),
         .init(vaultID: f.b.id, current: oldB, replacement: newB, confirmation: newB)]
    }
    private func registry(_ storage: GridStorage) throws -> VaultRegistry {
        try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(storage.read()))
    }

    func testGeometryAndValidationForEveryGridSize() {
        for size in [3, 4, 5] {
            var path = PatternPath(gridSize: size)
            path.append(0); path.append(size * size - 1)
            XCTAssertEqual(path.nodes, (0..<size).map { $0 * (size + 1) })
            path.append(0)
            XCTAssertEqual(path.nodes.count, size)
            let geometry = PatternGridGeometry(side: 300, gridSize: size)
            XCTAssertEqual(geometry.crossedNodes(from: geometry.center(0), to: geometry.center(size - 1)), Array(0..<size))
            XCTAssertTrue(PatternRules.isValid(Array(0..<4), gridSize: size))
            XCTAssertFalse(PatternRules.isValid([0, 1, 2, size * size], gridSize: size))
            XCTAssertFalse(PatternRules.isValid([0, 1, 2, 2], gridSize: size))
        }
        XCTAssertFalse(PatternRules.isValid([0, 1, 2, 3], gridSize: 6))
    }

    func testFirstVaultSavesGridPatternAndRecoveryTogetherForEverySize() async throws {
        for size in [3, 4, 5] {
            let storage = GridStorage(), auth = PatternAuthenticator(storage: storage)
            let lock = PatternLockStore(authenticator: auth)
            await lock.activate()
            XCTAssertEqual(lock.stage, .onboarding)
            try await lock.finishOnboarding(name: "My moments", pattern: newA, gridSize: size, recoveryPhrase: phrase)
            XCTAssertEqual(lock.stage, .unlocked)
            XCTAssertEqual(lock.gridSize, size)
            let vault = try XCTUnwrap(lock.unlockedVault)
            let restarted = PatternAuthenticator(storage: storage)
            let status = try await restarted.status()
            XCTAssertEqual(status.gridSize, size)
            try await restarted.validateRecoveryPhrase(vaultID: vault.id, phrase: phrase)
            let result = try await restarted.verify(newA)
            XCTAssertEqual(result, .accepted(vault))
            let data = try XCTUnwrap(storage.read())
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(phrase))
            let cold = PatternLockStore(authenticator: restarted)
            await cold.activate()
            XCTAssertEqual(cold.stage, .locked)
            XCTAssertEqual(cold.gridSize, size)
        }
    }

    func testOnboardingWizardCompletesAndOpensItsSelectedGrid() async throws {
        for size in PatternRules.supportedSizes {
            let storage = GridStorage(), auth = PatternAuthenticator(storage: storage)
            let lock = PatternLockStore(authenticator: auth)
            await lock.activate()
            let setup = OnboardingStore()
            setup.startSetup(); setup.gridSize = size; setup.chooseGrid()
            setup.submit(newA); setup.submit(newA)
            let recoveryPhrase = setup.phrase
            setup.confirmRecovery(); setup.confirmation = recoveryPhrase; setup.savedPhrase = true
            let view = OnboardingView(setup: setup) { name, pattern, gridSize, phrase in
                try await lock.finishOnboarding(name: name, pattern: pattern, gridSize: gridSize, recoveryPhrase: phrase)
            }
            await setup.finish(view.completion)
            XCTAssertNil(setup.error)
            XCTAssertEqual(lock.stage, .unlocked)
            XCTAssertEqual(lock.gridSize, size)
            let vault = try XCTUnwrap(lock.unlockedVault)
            try await auth.validateRecoveryPhrase(vaultID: vault.id, phrase: recoveryPhrase)
            XCTAssertTrue(setup.pattern.isEmpty)
            XCTAssertTrue(setup.phrase.isEmpty)
        }
    }

    func testInvalidOrFailedOnboardingNeverPersistsPartialVault() async throws {
        let storage = GridStorage(), auth = PatternAuthenticator(storage: storage)
        for size in [2, 6] {
            do { _ = try await auth.registerFirstVault(name: "Personal", pattern: newA, gridSize: size, recoveryPhrase: phrase); XCTFail() } catch {}
            XCTAssertNil(try storage.read())
        }
        do { _ = try await auth.registerFirstVault(name: "Personal", pattern: newA, gridSize: 3, recoveryPhrase: "short phrase"); XCTFail() } catch {}
        XCTAssertNil(try storage.read())
        storage.failWrite = true
        do { _ = try await auth.registerFirstVault(name: "Personal", pattern: newA, gridSize: 3, recoveryPhrase: phrase); XCTFail() } catch {}
        XCTAssertNil(try storage.read())
    }

    func testRecoverySetupSurvivesSwitchingAppsAndRegistersTheSavedPhrase() async throws {
        for custom in [false, true] {
            let storage = GridStorage(), auth = PatternAuthenticator(storage: storage)
            let lock = PatternLockStore(authenticator: auth)
            await lock.activate()
            let setup = OnboardingStore()
            setup.vaultName = "My moments"
            setup.startSetup(); setup.gridSize = 3; setup.chooseGrid()
            setup.submit(newA); setup.submit(newA)
            setup.useCustomPhrase = custom
            if custom { setup.customPhrase = phrase }
            let savedPhrase = setup.phrase

            for step in [OnboardingStep.recovery, .verifyRecovery] {
                if step == .verifyRecovery {
                    setup.confirmRecovery()
                    setup.confirmation = savedPhrase
                    setup.savedPhrase = true
                }
                for _ in 0..<2 {
                    lock.becameInactive()
                    lock.enteredBackground()
                    XCTAssertEqual(lock.stage, .onboarding, "Keep the same view mounted while saving the phrase in another app")
                    XCTAssertFalse(lock.isActive)
                    await lock.activate()
                    XCTAssertEqual(lock.stage, .onboarding)
                    XCTAssertEqual(setup.step, step)
                    XCTAssertEqual(setup.phrase, savedPhrase)
                    XCTAssertEqual(setup.pattern, newA)
                    XCTAssertEqual(setup.gridSize, 3)
                    XCTAssertEqual(setup.vaultName, "My moments")
                    XCTAssertNil(try storage.read(), "Unfinished onboarding should stay in memory")
                }
            }

            XCTAssertTrue(setup.canFinish)
            await setup.finish { name, pattern, size, phrase in
                try await lock.finishOnboarding(name: name, pattern: pattern, gridSize: size, recoveryPhrase: phrase)
            }
            XCTAssertNil(setup.error)
            XCTAssertEqual(lock.stage, .unlocked)
            let vault = try XCTUnwrap(lock.unlockedVault)
            try await auth.validateRecoveryPhrase(vaultID: vault.id, phrase: savedPhrase)
            XCTAssertTrue(setup.phrase.isEmpty)
            XCTAssertTrue(setup.pattern.isEmpty)

            lock.enteredBackground()
            await lock.activate()
            XCTAssertEqual(lock.stage, .locked, "Completed vaults must still lock on background")
        }
    }

    func testReturningToGridClearsFirstPatternAndRejectsShortOrWrongRecoveryConfirmation() {
        let setup = OnboardingStore()
        setup.startSetup(); setup.gridSize = 3; setup.chooseGrid()
        setup.submit(oldB)
        XCTAssertEqual(setup.step, .pattern)
        setup.submit(newA); setup.back(); setup.back()
        XCTAssertEqual(setup.step, .grid)
        XCTAssertTrue(setup.pattern.isEmpty)
        setup.gridSize = 4; setup.chooseGrid(); setup.submit(newA); setup.submit(newA)
        setup.useCustomPhrase = true; setup.customPhrase = "too short"; setup.confirmRecovery()
        XCTAssertEqual(setup.step, .recovery)
        setup.customPhrase = phrase; setup.confirmRecovery()
        setup.savedPhrase = true; setup.confirmation = "wrong"
        XCTAssertFalse(setup.canFinish)
        setup.confirmation = phrase.uppercased()
        XCTAssertTrue(setup.canFinish)
        setup.clearSecrets()
        XCTAssertFalse(setup.canFinish)
        XCTAssertTrue(setup.pattern.isEmpty)
    }

    func testLegacyVaultKeepsFiveByFiveAndSkipsOnboarding() async throws {
        let f = try await fixture()
        XCTAssertNil(try registry(f.storage).gridSize)
        let lock = PatternLockStore(authenticator: f.auth)
        await lock.activate()
        XCTAssertEqual(lock.stage, .locked)
        XCTAssertEqual(lock.gridSize, 5)
        await lock.submit(oldA)
        XCTAssertEqual(lock.unlockedVault, f.a)
    }

    func testGridResetPreservesMediaRecoveryAndAccessSettings() async throws {
        let f = try await fixture(protected: true)
        let folder = try await LibraryRepository(root: f.a.root(in: f.root)).createFolder(name: "Keep this", colorIndex: 2)
        try await f.auth.setDuressVault(vaultID: f.b.id, enabled: true, currentPattern: oldB)
        let before = try registry(f.storage), config = try await f.auth.gridConfiguration()
        let bio = GridFaceID()
        try await f.auth.replaceAllPatterns(configuration: config, gridSize: 3, replacements: replacements(f), faceID: bio)
        let after = try registry(f.storage)
        XCTAssertEqual(after.effectiveGridSize, 3)
        XCTAssertEqual(after.vaults.map(\.vault), before.vaults.map(\.vault))
        XCTAssertEqual(after.vaults.map(\.recovery), before.vaults.map(\.recovery))
        XCTAssertEqual(after.vaults.map(\.requiresFaceID), before.vaults.map(\.requiresFaceID))
        XCTAssertEqual(after.vaults.map(\.dummyVaultID), before.vaults.map(\.dummyVaultID))
        XCTAssertEqual(after.vaults.map(\.isDuressVault), before.vaults.map(\.isDuressVault))
        XCTAssertFalse(f.auth.security.backupsDisabled)
        XCTAssertEqual(bio.requests, 1)
        let media = try await LibraryRepository(root: f.a.root(in: f.root)).load()
        XCTAssertEqual(media, folder)
        let restarted = PatternAuthenticator(storage: f.storage, directory: f.root)
        guard case .requiresFaceID(let token) = try await restarted.verify(newA) else { return XCTFail("Protection removed") }
        let result = try await restarted.completeFaceID(token, result: .authenticated)
        XCTAssertEqual(result, .accepted(f.a))
        do { _ = try await restarted.verify(oldA); XCTFail("Old grid pattern accepted") } catch {}
    }

    func testIncompleteDuplicateAndUnconfirmedPatternsCannotChangeGrid() async throws {
        let f = try await fixture(), config = try await f.auth.gridConfiguration()
        let before = try registry(f.storage), all = replacements(f)
        let invalid: [[VaultPatternReplacement]] = [
            [all[0]], [all[0], all[0]],
            [all[0], .init(vaultID: f.b.id, current: oldB, replacement: newA, confirmation: newA)],
            [all[0], .init(vaultID: f.b.id, current: oldB, replacement: newB, confirmation: newA)]
        ]
        for replacements in invalid {
            do { try await f.auth.replaceAllPatterns(configuration: config, gridSize: 3, replacements: replacements, faceID: GridFaceID()); XCTFail("Invalid reset accepted") } catch {}
            XCTAssertEqual(try registry(f.storage), before)
        }
    }

    func testWrongCurrentPatternCannotResetAnotherVault() async throws {
        let f = try await fixture(), config = try await f.auth.gridConfiguration()
        let bad = [replacements(f)[0], VaultPatternReplacement(vaultID: f.b.id, current: oldA, replacement: newB, confirmation: newB)]
        do { try await f.auth.replaceAllPatterns(configuration: config, gridSize: 3, replacements: bad, faceID: GridFaceID()); XCTFail() } catch {}
        let after = try registry(f.storage)
        XCTAssertEqual(after.effectiveGridSize, 5)
        XCTAssertEqual(after.failedAttempts, 1)
        let result = try await f.auth.verify(oldA)
        XCTAssertEqual(result, .accepted(f.a))
    }

    func testFailedFaceIDOrKeychainWriteKeepsAllOldPatterns() async throws {
        let f = try await fixture(protected: true), config = try await f.auth.gridConfiguration()
        let before = try registry(f.storage), bio = GridFaceID()
        bio.result = .failed
        do { try await f.auth.replaceAllPatterns(configuration: config, gridSize: 3, replacements: replacements(f), faceID: bio); XCTFail() } catch {}
        XCTAssertEqual(try registry(f.storage), before)
        bio.result = .authenticated; f.storage.failWrite = true
        do { try await f.auth.replaceAllPatterns(configuration: config, gridSize: 3, replacements: replacements(f), faceID: bio); XCTFail() } catch {}
        XCTAssertEqual(try registry(f.storage), before)
    }

    func testConcurrentVaultChangeRejectsPendingGridReset() async throws {
        let f = try await fixture(protected: true), config = try await f.auth.gridConfiguration()
        let bio = GridFaceID()
        bio.duringAuthentication = { _ = try await f.auth.createVault(name: "New arrival", pattern: [0, 5, 10, 15, 20]) }
        do { try await f.auth.replaceAllPatterns(configuration: config, gridSize: 3, replacements: replacements(f), faceID: bio); XCTFail() } catch {}
        let after = try registry(f.storage)
        XCTAssertEqual(after.effectiveGridSize, 5)
        XCTAssertEqual(after.vaults.count, 3)
    }

    func testCancelledGridResetNeverCommits() async throws {
        let f = try await fixture(), config = try await f.auth.gridConfiguration()
        let before = try registry(f.storage)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await f.auth.replaceAllPatterns(configuration: config, gridSize: 3, replacements: replacements(f), faceID: GridFaceID())
        }
        do { try await task.value; XCTFail() } catch {}
        XCTAssertEqual(try registry(f.storage), before)
    }

    func testWizardUsesOldGridThenNewGridAndNeverSavesUntilEveryVaultIsConfirmed() async throws {
        let f = try await fixture(), before = try registry(f.storage)
        let wizard = GridChangeStore(authenticator: f.auth)
        await wizard.load(); wizard.gridSize = 4; wizard.begin()
        XCTAssertEqual(wizard.drawingSize, 5)
        await wizard.submit(oldA)
        XCTAssertEqual(wizard.drawingSize, 4)
        await wizard.submit(newA); await wizard.submit(newB)
        XCTAssertEqual(wizard.step, .confirm)
        await wizard.submit(newA)
        XCTAssertEqual(wizard.drawingSize, 5)
        XCTAssertEqual(wizard.vault, f.b)
        XCTAssertEqual(try registry(f.storage), before)
        await wizard.submit(oldB); await wizard.submit(newB); await wizard.submit(newB)
        XCTAssertEqual(wizard.step, .review)
        XCTAssertEqual(try registry(f.storage), before)
        let success = await wizard.save(faceID: GridFaceID())
        XCTAssertTrue(success)
        XCTAssertEqual(try registry(f.storage).effectiveGridSize, 4)
        XCTAssertTrue(wizard.replacements.isEmpty)
    }

    func testGridResetInvalidatesPendingFaceIDChallenge() async throws {
        let f = try await fixture(protected: true)
        guard case .requiresFaceID(let token) = try await f.auth.verify(oldA) else { return XCTFail() }
        let config = try await f.auth.gridConfiguration()
        try await f.auth.replaceAllPatterns(configuration: config, gridSize: 3, replacements: replacements(f), faceID: GridFaceID())
        do { _ = try await f.auth.completeFaceID(token, result: .authenticated); XCTFail("Stale biometric challenge accepted") } catch {}
        let lock = PatternLockStore(authenticator: f.auth, faceID: GridFaceID())
        await lock.activate()
        XCTAssertEqual(lock.gridSize, 3)
        await lock.submit(newA)
        XCTAssertEqual(lock.unlockedVault, f.a)
        lock.enteredBackground(); await lock.activate()
        XCTAssertEqual(lock.stage, .locked)
        XCTAssertEqual(lock.gridSize, 3)
    }

    func testCreationRecoveryAndPatternChangeUseSavedGrid() async throws {
        let storage = GridStorage(), auth = PatternAuthenticator(storage: storage)
        let vault = try await auth.registerFirstVault(name: "Personal", pattern: newA, gridSize: 3, recoveryPhrase: phrase)
        do { _ = try await auth.createVault(name: "Bad", pattern: oldB); XCTFail() } catch {}
        do { _ = try await auth.recover(phrase: phrase, newPattern: oldB); XCTFail() } catch {}
        do { try await auth.changePattern(vaultID: vault.id, current: newA, replacement: oldB); XCTFail() } catch {}
        _ = try await auth.recover(phrase: phrase, newPattern: newB)
        let result = try await auth.verify(newB)
        XCTAssertEqual(result, .accepted(vault))
    }
}
