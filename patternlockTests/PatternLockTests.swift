import Foundation
import Security
import XCTest
import UIKit
@testable import patternlock

final class PatternGeometryTests: XCTestCase {
    func testGridHas25DotsAndRequiresFourDistinctValidNodes() {
        XCTAssertEqual(PatternRules.dotCount, 25)
        XCTAssertTrue(PatternRules.isValid([0, 6, 12, 18]))
        XCTAssertTrue(PatternRules.isValid(Array(0..<25)))
        XCTAssertFalse(PatternRules.isValid([0, 1, 2]))
        XCTAssertFalse(PatternRules.isValid([0, 1, 2, 2]))
        XCTAssertFalse(PatternRules.isValid([0, 1, 2, 25]))
        XCTAssertFalse(PatternRules.isValid([-1, 1, 2, 3]))
    }

    func testCrossedDotsAreIncludedAndCannotBeReused() {
        var path = PatternPath()
        path.append(0)
        path.append(24)
        XCTAssertEqual(path.nodes, [0, 6, 12, 18, 24])
        path.append(0)
        XCTAssertEqual(path.nodes, [0, 6, 12, 18, 24])
        path.reset()
        path.append(0)
        path.append(14)
        XCTAssertEqual(path.nodes, [0, 7, 14])
        path.reset()
        path.append(0)
        path.append(7)
        XCTAssertEqual(path.nodes, [0, 7])
    }

    func testFastSwipesHitEveryCrossedDotAtDifferentGridSizes() {
        for side: CGFloat in [240, 340, 400] {
            let grid = PatternGridGeometry(side: side)
            XCTAssertEqual(grid.crossedNodes(from: grid.center(0), to: grid.center(4)), [0, 1, 2, 3, 4])
            XCTAssertEqual(grid.crossedNodes(from: grid.center(24), to: grid.center(0)), [24, 18, 12, 6, 0])
            XCTAssertEqual(grid.crossedNodes(from: grid.center(12), to: grid.center(12)), [12])
            XCTAssertTrue(grid.crossedNodes(from: CGPoint(x: -50, y: -50), to: CGPoint(x: -20, y: -20)).isEmpty)
        }
    }
}

final class MemoryPatternStorage: ResettablePatternCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    init(data: Data? = nil) { value = data }
    func read() throws -> Data? { lock.withLock { value } }
    func remove() throws { lock.withLock { value = nil } }
    func create(_ data: Data) throws {
        try lock.withLock {
            guard value == nil else { throw PatternCredentialError.alreadyRegistered }
            value = data
        }
    }
    func update(_ data: Data) throws {
        try lock.withLock {
            guard value != nil else { throw PatternCredentialError.noPattern }
            value = data
        }
    }
}

final class PatternCredentialTests: XCTestCase {
    private let pattern = [0, 1, 2, 7, 12]
    private let wrong = [0, 5, 10, 15, 20]

    func testSaltedVerifierPersistsAndOnlyMatchesExactPattern() async throws {
        let storage = MemoryPatternStorage()
        let service = PatternAuthenticator(storage: storage)
        try await service.register(pattern)
        let record = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(storage.read())).vaults[0].pattern
        XCTAssertEqual(record.salt.count, 32)
        XCTAssertEqual(record.verifier.count, 32)
        XCTAssertEqual(record.rounds, 600_000)
        let fresh = PatternAuthenticator(storage: storage)
        let status = try await fresh.status()
        XCTAssertTrue(status.isRegistered)
        let rejected = try await fresh.verify(wrong, now: Date())
        XCTAssertEqual(rejected, .rejected(retryAfter: nil))
        let accepted = try await fresh.verify(pattern, now: Date())
        XCTAssertEqual(accepted, .accepted(.personal))
        let secondStorage = MemoryPatternStorage()
        try await PatternAuthenticator(storage: secondStorage).register(pattern)
        let secondRecord = try JSONDecoder().decode(VaultRegistry.self, from: XCTUnwrap(secondStorage.read())).vaults[0].pattern
        XCTAssertNotEqual(record.salt, secondRecord.salt)
        XCTAssertNotEqual(record.verifier, secondRecord.verifier)
        do { try await fresh.register(wrong); XCTFail("Existing pattern replaced") } catch { }
    }

    func testCooldownSurvivesRelaunchAndExpires() async throws {
        let storage = MemoryPatternStorage()
        let service = PatternAuthenticator(storage: storage)
        try await service.register(pattern)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for attempt in 1...5 {
            let result = try await service.verify(wrong, now: now)
            XCTAssertEqual(result, .rejected(retryAfter: attempt < 5 ? nil : now.addingTimeInterval(30)))
        }
        let fresh = PatternAuthenticator(storage: storage)
        let status = try await fresh.status()
        XCTAssertEqual(status.retryAfter, now.addingTimeInterval(30))
        let blockedCorrectPattern = try await fresh.verify(pattern, now: now.addingTimeInterval(10))
        XCTAssertEqual(blockedCorrectPattern, .rejected(retryAfter: now.addingTimeInterval(30)))
        let afterCooldown = try await fresh.verify(pattern, now: now.addingTimeInterval(31))
        XCTAssertEqual(afterCooldown, .accepted(.personal))
        let reset = try await fresh.status()
        XCTAssertNil(reset.retryAfter)
    }

    func testInvalidCredentialFailsClosedInsteadOfAllowingRegistration() async throws {
        let corrupt = Data("invalid record".utf8)
        let storage = MemoryPatternStorage(data: corrupt)
        let service = PatternAuthenticator(storage: storage)
        do { _ = try await service.status(); XCTFail("Corrupt credential accepted") } catch { }
        do { try await service.register(pattern); XCTFail("Corrupt credential overwritten") } catch { }
        XCTAssertEqual(try storage.read(), corrupt)
    }

    func testKeychainRoundTripUsesWhenUnlockedAccessibility() async throws {
        let serviceName = "jp.gm.patternlock.tests." + UUID().uuidString
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: serviceName]
        defer { SecItemDelete(query as CFDictionary) }
        let service = PatternAuthenticator(storage: KeychainPatternStorage(service: serviceName))
        try await service.register(pattern)
        let fresh = PatternAuthenticator(storage: KeychainPatternStorage(service: serviceName))
        let result = try await fresh.verify(pattern, now: Date())
        XCTAssertEqual(result, .accepted(.personal))
        var attributeQuery = query
        attributeQuery[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributeQuery as CFDictionary, &attributes), errSecSuccess)
        let values = try XCTUnwrap(attributes as? [String: Any])
        XCTAssertEqual(values[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlocked as String)
    }
}

private actor TestAuthenticator: PatternAuthenticating {
    private var pattern: [Int]?
    let failsRead: Bool
    let failsWrite: Bool
    let deferred: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var registrations = 0

    init(pattern: [Int]? = nil, failsRead: Bool = false, failsWrite: Bool = false, deferred: Bool = false) {
        self.pattern = pattern
        self.failsRead = failsRead
        self.failsWrite = failsWrite
        self.deferred = deferred
    }
    func status() throws -> PatternLockStatus {
        if failsRead { throw PatternCredentialError.inaccessible }
        return PatternLockStatus(isRegistered: pattern != nil, retryAfter: nil)
    }
    func register(_ nodes: [Int]) async throws -> Vault {
        if deferred { await suspendOperation() }
        if failsWrite { throw PatternCredentialError.inaccessible }
        pattern = nodes
        registrations += 1
        return .personal
    }
    func registerFirstVault(name: String, pattern: [Int], gridSize: Int, recoveryPhrase: String) async throws -> Vault {
        try await register(pattern)
    }
    func createVault(name: String, pattern: [Int]) async throws -> Vault {
        if failsWrite { throw PatternCredentialError.inaccessible }
        return Vault(id: UUID().uuidString, name: name)
    }
    func verify(_ nodes: [Int], now: Date) async throws -> PatternVerification {
        if deferred { await suspendOperation() }
        return nodes == pattern ? .accepted(.personal) : .rejected(retryAfter: nil)
    }
    private func suspendOperation() async {
        started = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func completeOperation() { continuation?.resume(); continuation = nil }
}

@MainActor final class PatternLockStoreTests: XCTestCase {
    private let pattern = [0, 1, 2, 7, 12]
    private let wrong = [0, 5, 10, 15, 20]

    func testRegistrationRequiresMatchingConfirmationBeforeSaving() async {
        let auth = TestAuthenticator()
        let lock = PatternLockStore(authenticator: auth)
        await lock.activate()
        XCTAssertEqual(lock.stage, .onboarding)
        let setup = OnboardingStore()
        setup.startSetup(); setup.chooseGrid(); setup.submit(pattern)
        XCTAssertEqual(setup.step, .confirm)
        setup.submit(wrong)
        XCTAssertEqual(setup.step, .confirm)
        XCTAssertNotNil(setup.error)
        var registrations = await auth.registrations
        XCTAssertEqual(registrations, 0)
        setup.submit(pattern)
        XCTAssertEqual(setup.step, .recovery)
        setup.confirmRecovery()
        await setup.finish { name, pattern, size, phrase in
            try await lock.finishOnboarding(name: name, pattern: pattern, gridSize: size, recoveryPhrase: phrase)
        }
        registrations = await auth.registrations
        XCTAssertEqual(registrations, 0, "A saved phrase must be confirmed first")
        setup.confirmation = setup.phrase; setup.savedPhrase = true
        await setup.finish { name, pattern, size, phrase in
            try await lock.finishOnboarding(name: name, pattern: pattern, gridSize: size, recoveryPhrase: phrase)
        }
        XCTAssertEqual(lock.stage, .unlocked)
        registrations = await auth.registrations
        XCTAssertEqual(registrations, 1)
        XCTAssertTrue(setup.pattern.isEmpty)
        XCTAssertTrue(setup.phrase.isEmpty)
    }

    func testShortPatternsAndStartOverDoNotSaveCredentials() async {
        let setup = OnboardingStore()
        setup.startSetup(); setup.chooseGrid(); setup.submit([0, 1, 2])
        XCTAssertEqual(setup.step, .pattern)
        XCTAssertNotNil(setup.error)
        setup.submit(pattern); setup.back()
        XCTAssertEqual(setup.step, .pattern)
        XCTAssertTrue(setup.pattern.isEmpty)
        setup.submit(wrong); setup.submit(pattern)
        XCTAssertEqual(setup.step, .confirm)
        XCTAssertTrue(setup.phrase.isEmpty)
    }

    func testColdLaunchAndBackgroundAlwaysRequirePattern() async {
        let auth = TestAuthenticator(pattern: pattern)
        let lock = PatternLockStore(authenticator: auth)
        await lock.activate()
        XCTAssertEqual(lock.stage, .locked)
        await lock.submit(wrong)
        XCTAssertEqual(lock.stage, .locked)
        await lock.submit(pattern)
        XCTAssertEqual(lock.stage, .unlocked)
        lock.becameInactive()
        lock.enteredBackground()
        XCTAssertNotEqual(lock.stage, .unlocked)
        await lock.activate()
        XCTAssertEqual(lock.stage, .locked)
        let coldLaunch = PatternLockStore(authenticator: auth)
        await coldLaunch.activate()
        XCTAssertEqual(coldLaunch.stage, .locked)
    }

    func testBriefInactivityDoesNotDiscardUnlockedSession() async {
        let lock = PatternLockStore(authenticator: TestAuthenticator(pattern: pattern))
        await lock.activate()
        await lock.submit(pattern)
        let revision = lock.inputRevision
        lock.becameInactive()
        XCTAssertFalse(lock.isActive)
        XCTAssertGreaterThan(lock.inputRevision, revision)
        await lock.activate()
        XCTAssertEqual(lock.stage, .unlocked)
    }

    func testBackgroundKeepsOnboardingMountedWithoutRegisteringAVault() async {
        let auth = TestAuthenticator()
        let lock = PatternLockStore(authenticator: auth)
        await lock.activate()
        XCTAssertEqual(lock.stage, .onboarding)
        lock.becameInactive()
        lock.enteredBackground()
        // Both the scene notifications and SwiftUI scenePhase report this.
        lock.enteredBackground()
        XCTAssertEqual(lock.stage, .onboarding, "Changing stage would discard the onboarding view and its recovery phrase")
        XCTAssertFalse(lock.isActive)
        XCTAssertNil(lock.unlockedVault)
        await lock.activate()
        XCTAssertEqual(lock.stage, .onboarding)
        let registrations = await auth.registrations
        XCTAssertEqual(registrations, 0)
    }

    func testLateVerificationCannotUnlockAfterBackgrounding() async {
        let auth = TestAuthenticator(pattern: pattern, deferred: true)
        let lock = PatternLockStore(authenticator: auth)
        await lock.activate()
        let verification = Task { await lock.submit(pattern) }
        await auth.waitUntilStarted()
        lock.enteredBackground()
        await auth.completeOperation()
        await verification.value
        XCTAssertNotEqual(lock.stage, .unlocked)
        await lock.activate()
        XCTAssertEqual(lock.stage, .locked)
    }

    func testLateRegistrationCannotUnlockAfterBackgrounding() async {
        let auth = TestAuthenticator(deferred: true)
        let lock = PatternLockStore(authenticator: auth)
        await lock.activate()
        let registration = Task { try? await lock.finishOnboarding(name: "Personal", pattern: pattern, gridSize: 5, recoveryPhrase: "test recovery phrase") }
        await auth.waitUntilStarted()
        lock.enteredBackground()
        await auth.completeOperation()
        await registration.value
        XCTAssertNotEqual(lock.stage, .unlocked)
        await lock.activate()
        XCTAssertEqual(lock.stage, .locked)
    }

    func testKeychainFailuresNeverExposeLibraryOrAllowNewEnrollment() async {
        let unreadable = PatternLockStore(authenticator: TestAuthenticator(failsRead: true))
        await unreadable.activate()
        XCTAssertEqual(unreadable.stage, .unavailable)
        await unreadable.submit(pattern)
        XCTAssertEqual(unreadable.stage, .unavailable)
        let unwritable = PatternLockStore(authenticator: TestAuthenticator(failsWrite: true))
        await unwritable.activate()
        do {
            try await unwritable.finishOnboarding(name: "Personal", pattern: pattern, gridSize: 5, recoveryPhrase: "test recovery phrase")
            XCTFail("Failed save exposed the library")
        } catch {}
        XCTAssertEqual(unwritable.stage, .onboarding)
        XCTAssertNil(unwritable.unlockedVault)
    }
}

@MainActor final class ScenePrivacyShieldTests: XCTestCase {
    func testPrivacyWindowCoversPresentedContentUntilActivationFinishes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let hostWindow = UIWindow(windowScene: scene)
        let controller = UIViewController()
        hostWindow.rootViewController = controller
        hostWindow.isHidden = false
        let anchor = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        controller.view.addSubview(anchor)
        hostWindow.layoutIfNeeded()
        var events: [String] = []
        var activation: CheckedContinuation<Void, Never>?
        let owner = ScenePrivacyShield(
            onInactive: { events.append("inactive") },
            onBackground: { events.append("background") },
            onActive: { await withCheckedContinuation { activation = $0 }; events.append("active") }
        )
        let coordinator = ScenePrivacyShield.Coordinator(owner: owner)
        coordinator.anchor = anchor
        coordinator.observe()
        defer { coordinator.stop(); hostWindow.isHidden = true }
        let initialWindows = Set(scene.windows.map(ObjectIdentifier.init))
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        let shield = try XCTUnwrap(scene.windows.first { !initialWindows.contains(ObjectIdentifier($0)) && $0.windowLevel > .alert })
        XCTAssertFalse(shield.isHidden)
        XCTAssertTrue(shield.isUserInteractionEnabled)
        XCTAssertEqual(events, ["inactive"])
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        XCTAssertEqual(events, ["inactive", "background"])
        XCTAssertFalse(shield.isHidden)
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        for _ in 0..<100 where activation == nil { await Task.yield() }
        XCTAssertNotNil(activation)
        XCTAssertFalse(shield.isHidden, "Privacy cover must remain while the lock is loading")
        activation?.resume()
        for _ in 0..<100 where !shield.isHidden { await Task.yield() }
        XCTAssertTrue(shield.isHidden)
        XCTAssertEqual(events, ["inactive", "background", "active"])
    }
}
