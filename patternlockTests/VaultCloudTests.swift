import Foundation
import XCTest
@testable import patternlock

@MainActor final class VaultCloudTests: XCTestCase {
    private let pattern = [0, 1, 2, 7, 12]
    private let secondPattern = [4, 9, 14, 19, 24]
    private let phrase = "these eight chosen words make a sufficiently long recovery phrase"

    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }
    private func equal<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, message, file: file, line: line) }
    private func truth(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func falsity(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }

    private func fixture(unlimited: Bool = true) async throws -> (PatternAuthenticator, Vault, LibraryStore, TestCloudTransport, VaultCloudService, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "CloudTests-" + UUID().uuidString)
        try LocalVaultStorage.prepareDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let security = VaultSecurityState()
        let purchases = PurchaseAccess(); purchases.update(isUnlimited: unlimited)
        let auth = PatternAuthenticator(storage: MemoryPatternStorage(), security: security, purchaseAccess: purchases, directory: root)
        let vault = try await auth.registerFirstVault(name: "Secret name", pattern: pattern, gridSize: 5, recoveryPhrase: phrase)
        let store = LibraryStore(root: vault.root(in: root), security: security, purchaseAccess: purchases)
        await store.load()
        let transport = TestCloudTransport()
        return (auth, vault, store, transport, VaultCloudService(transport: transport, authenticator: auth), root)
    }

    func testBackupIsOptInAndDoesNotContactCloudBeforeEnabled() async throws {
        let (auth, vault, store, transport, service, _) = try await fixture()
        try await service.synchronize(vault: vault, store: store)
        let entry = try await auth.settings(for: vault.id)
        let calls = await transport.accountCalls
        XCTAssertNil(entry.cloudBackup)
        equal(calls, 0)
    }

    func testCloudBackupRoundTripEncryptsNamesAndRestoresWithoutFilePicker() async throws {
        let (auth, vault, store, transport, service, _) = try await fixture()
        _ = await store.saveFolder(nil, name: "Secret folder", colorIndex: 2)
        try await service.enableBackup(vault: vault, store: store, phrase: phrase)
        let configuration = try unwrap(try await auth.settings(for: vault.id).cloudBackup)
        let saved = try unwrap(await transport.backupRecords[configuration.id])
        XCTAssertNil(saved.archive.range(of: Data(vault.name.utf8)))
        XCTAssertNil(saved.archive.range(of: Data("Secret folder".utf8)))
        XCTAssertNil(saved.metadata.range(of: Data(vault.name.utf8)))
        XCTAssertNil(try JSONEncoder().encode(saved.recovery).range(of: Data(configuration.secret.utf8)))
        let restored = try await service.prepareBackup(id: configuration.id, phrase: phrase)
        equal(restored.snapshot, store.snapshot)
        equal(restored.name, vault.name)
        XCTAssertNotNil(configuration.lastCompleted)
        do { _ = try await service.prepareBackup(id: configuration.id, phrase: "wrong words"); XCTFail("Wrong phrase restored backup") } catch {}
    }

    func testRecoveryRotationPublishesNewWrapperAndOldPhraseStopsWorking() async throws {
        let (auth, vault, store, _, service, _) = try await fixture()
        try await service.enableBackup(vault: vault, store: store, phrase: phrase)
        let id = try unwrap(try await auth.settings(for: vault.id).cloudBackup?.id)
        let replacement = try RecoveryPhrase.generate()
        try await auth.setRecoveryPhrase(vaultID: vault.id, phrase: replacement, currentPattern: pattern)
        try await service.synchronize(vault: vault, store: store)
        _ = try await service.prepareBackup(id: id, phrase: replacement)
        do { _ = try await service.prepareBackup(id: id, phrase: phrase); XCTFail("Old phrase still worked after completed rotation") } catch {}
    }

    func testFailedUploadKeepsLastCompletedBackupAndRetryPublishesChanges() async throws {
        let (auth, vault, store, transport, service, _) = try await fixture()
        try await service.enableBackup(vault: vault, store: store, phrase: phrase)
        let before = try unwrap(try await auth.settings(for: vault.id).cloudBackup)
        _ = await store.saveFolder(nil, name: "New folder", colorIndex: 1)
        await transport.setOffline(true)
        do { try await service.synchronize(vault: vault, store: store); XCTFail("Offline upload succeeded") } catch {}
        let failed = try await auth.settings(for: vault.id).cloudBackup
        equal(before, failed)
        await transport.setOffline(false)
        let old = try await service.prepareBackup(id: before.id, phrase: phrase)
        truth(old.snapshot.folders.isEmpty)
        try await service.synchronize(vault: vault, store: store)
        let new = try await service.prepareBackup(id: before.id, phrase: phrase)
        equal(new.snapshot, store.snapshot)
    }

    func testDisablingBackupQueuesDeletionOfflineAndPreservesLocalVault() async throws {
        let (auth, vault, store, transport, service, _) = try await fixture()
        try await service.enableBackup(vault: vault, store: store, phrase: phrase)
        await transport.setOffline(true)
        try await service.disableBackup(vaultID: vault.id)
        let disabled = try await auth.settings(for: vault.id)
        XCTAssertNil(disabled.cloudBackup)
        equal(try await auth.pendingCloudDeletions().count, 1)
        XCTAssertNotNil(service.deletionError)
        await transport.setOffline(false)
        await service.processDeletions()
        truth(try await auth.pendingCloudDeletions().isEmpty)
        truth(await transport.backupRecords.isEmpty)
        equal(try await auth.verify(pattern), .accepted(vault))
    }

    func testDifferentAppleAccountCannotOverwriteOrDeleteBackup() async throws {
        let (auth, vault, store, transport, service, _) = try await fixture()
        try await service.enableBackup(vault: vault, store: store, phrase: phrase)
        await transport.setAccount("someone-else")
        do { try await service.synchronize(vault: vault, store: store, force: true); XCTFail("Changed account uploaded") } catch {}
        try await service.disableBackup(vaultID: vault.id)
        equal(try await auth.pendingCloudDeletions().count, 1)
        equal(await transport.backupRecords.count, 1)
    }

    func testSharingUsesIndependentSecretsAndFreeRecipientIsReadOnly() async throws {
        let (auth, vault, store, transport, service, root) = try await fixture()
        _ = await store.saveFolder(nil, name: "For you", colorIndex: 3)
        let sharingPhrase = try await service.createShare(vault: vault, store: store, label: "Friend", policy: VaultSharePolicy(allowsExport: false))
        XCTAssertNotEqual(sharingPhrase, phrase)
        let share = try unwrap(try await auth.settings(for: vault.id).ownedShares?.first)
        XCTAssertNotEqual(share.secret, sharingPhrase)
        let inviteData = try JSONEncoder().encode(try unwrap(await transport.invitations[share.invitationID]))
        XCTAssertNil(inviteData.range(of: Data(share.secret.utf8)))
        XCTAssertNil(inviteData.range(of: Data(sharingPhrase.utf8)))
        await transport.setAccount("recipient")
        let recipientSecurity = VaultSecurityState()
        let recipientAuth = PatternAuthenticator(storage: MemoryPatternStorage(), security: recipientSecurity, purchaseAccess: PurchaseAccess(), directory: root)
        let recipientService = VaultCloudService(transport: transport, authenticator: recipientAuth)
        let claim = try await recipientService.prepareJoin(phrase: sharingPhrase)
        let local = Vault(id: UUID().uuidString, name: "Received")
        try await recipientAuth.installRestoredVault(local, pattern: secondPattern, preparedDirectory: claim.prepared.directory, directory: root, lease: claim.prepared.lease, joinedShare: claim.joined)
        let recipientStore = LibraryStore(root: local.root(in: root), security: recipientSecurity)
        let joined = try await recipientService.openShared(vault: local, store: recipientStore)
        equal(joined?.opens, 1)
        truth(recipientStore.isReadOnly)
        falsity(recipientStore.allowsExport)
        falsity(await recipientStore.saveFolder(nil, name: "Forbidden", colorIndex: 0))
        do { _ = try await recipientStore.repository.delete(ids: []); XCTFail("Shared media was writable") } catch {}
        do { _ = try await recipientStore.repository.export(ids: []); XCTFail("Export restriction bypassed") } catch {}
        equal(recipientStore.snapshot, store.snapshot)
        await transport.setOffline(true)
        do { _ = try await recipientService.openShared(vault: local, store: recipientStore); XCTFail("Cached content opened offline") } catch {}
        equal(try await recipientAuth.settings(for: local.id).joinedShare?.opens, 1)
        await transport.setOffline(false)
        await transport.setAccount("owner")
        _ = await store.saveFolder(nil, name: "An update", colorIndex: 1)
        try await service.synchronize(vault: vault, store: store)
        await transport.setAccount("recipient")
        _ = try await recipientService.openShared(vault: local, store: recipientStore)
        equal(recipientStore.snapshot, store.snapshot)
        equal(try await recipientAuth.settings(for: local.id).joinedShare?.opens, 2)
        await transport.setAccount("owner")
        try await service.revoke(vaultID: vault.id, shareID: share.id)
        await transport.setAccount("recipient")
        do { _ = try await recipientService.openShared(vault: local, store: recipientStore); XCTFail("Revoked recipient opened cached media") } catch {}
    }

    func testInterruptedInvitationIsRevokedBeforeAutomaticPublishing() async throws {
        let (auth, vault, store, transport, service, _) = try await fixture()
        let pending = OwnedVaultShare(accountID: "owner", secret: try RecoveryPhrase.generate(), invitationID: "orphan-invitation", label: "Interrupted", policy: VaultSharePolicy())
        try await auth.addOwnedShare(vaultID: vault.id, share: pending)
        try await service.synchronize(vault: vault, store: store)
        await service.processDeletions()
        truth(try await auth.settings(for: vault.id).ownedShares?.isEmpty ?? true)
        truth(await transport.shareRecords.isEmpty)
    }

    func testSharedOpenLimitPersistsAndCannotBeUsedAsDuressOrDummy() async throws {
        let (auth, vault, store, transport, service, root) = try await fixture()
        let sharingPhrase = try await service.createShare(vault: vault, store: store, label: "Once", policy: VaultSharePolicy(maximumOpens: 1))
        await transport.setAccount("recipient")
        let security = VaultSecurityState()
        let credentials = MemoryPatternStorage()
        let recipient = PatternAuthenticator(storage: credentials, security: security, directory: root)
        let client = VaultCloudService(transport: transport, authenticator: recipient)
        let claim = try await client.prepareJoin(phrase: sharingPhrase)
        let shared = Vault(id: UUID().uuidString, name: "One open")
        try await recipient.installRestoredVault(shared, pattern: pattern, preparedDirectory: claim.prepared.directory, directory: root, lease: claim.prepared.lease, joinedShare: claim.joined)
        let library = LibraryStore(root: shared.root(in: root), security: security)
        _ = try await client.openShared(vault: shared, store: library)
        let relaunched = PatternAuthenticator(storage: credentials, security: security, directory: root)
        let relaunchedClient = VaultCloudService(transport: transport, authenticator: relaunched)
        do { _ = try await relaunchedClient.openShared(vault: shared, store: library); XCTFail("Relaunch reset open counter") } catch {}
        do { try await recipient.setDuressVault(vaultID: shared.id, enabled: true, currentPattern: pattern); XCTFail("Shared duress could bypass access checks") } catch {}
        let owned = try await recipient.createVault(name: "Owned", pattern: secondPattern)
        truth(try await recipient.availableDummyVaults(for: owned.id).isEmpty)
        // Another Apple Account cannot claim this invitation in the transport contract.
        await transport.setAccount("third-account")
        do { _ = try await client.prepareJoin(phrase: sharingPhrase); XCTFail("Invitation claimed twice") } catch {}
        _ = auth // Keep the owner registry alive for this fixture.
    }

    func testDuressStopsBackupAndDurablyQueuesEveryShareRevocation() async throws {
        let (auth, vault, store, transport, service, _) = try await fixture()
        try await service.enableBackup(vault: vault, store: store, phrase: phrase)
        _ = try await service.createShare(vault: vault, store: store, label: "One", policy: VaultSharePolicy())
        _ = try await service.createShare(vault: vault, store: store, label: "Two", policy: VaultSharePolicy())
        let other = try await auth.createVault(name: "Other", pattern: secondPattern)
        try await auth.setDuressVault(vaultID: vault.id, enabled: true, currentPattern: pattern)
        await transport.setOffline(true)
        _ = try await auth.verify(pattern)
        let survivor = try await auth.settings(for: vault.id)
        XCTAssertNil(survivor.cloudBackup)
        truth(survivor.ownedShares?.isEmpty ?? true)
        truth(auth.security.backupsDisabled)
        falsity(auth.security.allowsAccess(to: other.id))
        equal(try await auth.pendingCloudDeletions().count, 2)
        await service.processDeletions()
        equal(try await auth.pendingCloudDeletions().count, 2)
        await transport.setOffline(false)
        await service.processDeletions()
        truth(await transport.shareRecords.isEmpty)
        equal(await transport.backupRecords.count, 1, "Duress keeps prior personal backups available for recovery")
    }

    func testMetadataAndPhraseEnvelopesRejectTamperingAndWrongContext() throws {
        let generated = try RecoveryPhrase.generate()
        equal(try VaultCloudCrypto.invitationID(generated), try VaultCloudCrypto.invitationID("  " + generated.uppercased() + "\n"))
        XCTAssertThrowsError(try VaultCloudCrypto.invitationID("a short chosen password"))
        let envelope = try VaultCloudCrypto.wrap("secret", phrase: generated, context: "backup:a")
        XCTAssertThrowsError(try VaultCloudCrypto.unwrap(String.self, envelope: envelope, phrase: generated, context: "invite:a"))
        let metadata = CloudVaultMetadata(version: "1", name: "Private", digest: Data([1]))
        var sealed = try VaultCloudCrypto.sealMetadata(metadata, secret: generated, context: "zone-a")
        XCTAssertThrowsError(try VaultCloudCrypto.openMetadata(sealed, secret: generated, context: "zone-b"))
        sealed[sealed.count - 1] ^= 1
        XCTAssertThrowsError(try VaultCloudCrypto.openMetadata(sealed, secret: generated, context: "zone-a"))
    }

    func testSharePoliciesRejectExpiryAndExhaustedOpens() throws {
        XCTAssertThrowsError(try VaultSharePolicy(expiresAt: .distantPast).check(opens: 0))
        let limited = VaultSharePolicy(maximumOpens: 2)
        XCTAssertNoThrow(try limited.check(opens: 1))
        XCTAssertThrowsError(try limited.check(opens: 2))
    }

    func testAccessMonitorOutlivesPresentationAndStoppingOneWindowKeepsOthersChecking() async throws {
        let (auth, _, _, transport, _, _) = try await fixture()
        let service = VaultCloudService(transport: transport, authenticator: auth, accessCheckInterval: .milliseconds(5))
        let joined = JoinedVaultShare(accountID: "recipient", zoneName: "missing", ownerName: "owner", secret: "unused", policy: VaultSharePolicy())
        let firstScope = UUID(), secondScope = UUID()
        let first = service.monitor(joined, scope: firstScope)
        let second = service.monitor(joined, scope: secondScope)
        service.stopViewingSessions(scope: firstScope)
        for _ in 0..<100 where second.error == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(first.error, "The closed window's monitor should be cancelled")
        XCTAssertNotNil(second.error, "An independently owned monitor keeps checking without a view task")
        service.stopViewingSessions()
    }

    func testVaultDeletionAlsoRemovesInterruptedSharedReplacementCopies() async throws {
        let (auth, vault, _, _, _, root) = try await fixture()
        let staged = ["ReplacingVaultOld-", "ReplacingVaultNew-"].map { root.appending(path: $0 + vault.id) }
        for url in staged { try LocalVaultStorage.prepareDirectory(url) }
        try await auth.deleteVault(vaultID: vault.id, currentPattern: pattern, directory: root)
        for url in staged { falsity(FileManager.default.fileExists(atPath: url.path)) }
    }
}

private actor TestCloudTransport: VaultCloudTransport {
    struct Record: Sendable {
        let archive: Data
        let metadata: Data
        let recovery: CloudEnvelope?
    }
    var account = "owner"
    var offline = false
    var accountCalls = 0
    var backupRecords: [String: Record] = [:]
    var shareRecords: [String: Record] = [:]
    var invitations: [String: CloudEnvelope] = [:]
    var claimers: [String: String] = [:]
    func setAccount(_ value: String) { account = value }
    func setOffline(_ value: Bool) { offline = value }
    private func check() throws { if offline { throw URLError(.notConnectedToInternet) } }
    func accountID() throws -> String { accountCalls += 1; try check(); return account }
    func backups() throws -> [CloudBackupSummary] { try check(); return backupRecords.keys.map { CloudBackupSummary(id: $0, date: .now) } }
    func uploadBackup(id: String, archive: URL, metadata: Data, recovery: CloudEnvelope) throws {
        try check(); backupRecords[id] = Record(archive: try Data(contentsOf: archive), metadata: metadata, recovery: recovery)
    }
    func downloadBackup(id: String) throws -> CloudVaultDownload { try check(); return try download(backupRecords[id]) }
    func uploadShare(zone: String, archive: URL, metadata: Data) throws {
        try check(); shareRecords[zone] = Record(archive: try Data(contentsOf: archive), metadata: metadata, recovery: nil)
    }
    func createInvitation(zone: String) throws -> URL { try check(); return URL(string: "https://www.icloud.com/share/" + zone)! }
    func publishInvitation(id: String, envelope: CloudEnvelope) throws { try check(); invitations[id] = envelope }
    func invitation(id: String) throws -> CloudEnvelope { try check(); guard let result = invitations[id] else { throw VaultCloudError.unavailable }; return result }
    func acceptInvitation(_ url: URL, expectedZone: String) throws -> (zone: String, owner: String) {
        try check()
        guard claimers[expectedZone] == nil || claimers[expectedZone] == account else { throw VaultCloudError.unavailable }
        claimers[expectedZone] = account
        return (expectedZone, "owner")
    }
    func sharedMetadata(zone: String, owner: String) throws -> Data {
        try check(); guard claimers[zone] == account, let record = shareRecords[zone] else { throw VaultCloudError.unavailable }; return record.metadata
    }
    func downloadShare(zone: String, owner: String) throws -> CloudVaultDownload { _ = try sharedMetadata(zone: zone, owner: owner); return try download(shareRecords[zone]) }
    func delete(_ deletion: CloudDeletion) throws {
        try check()
        if let zone = deletion.zoneName { shareRecords[zone] = nil; invitations[deletion.recordID] = nil }
        else { backupRecords[deletion.recordID] = nil }
    }
    private func download(_ record: Record?) throws -> CloudVaultDownload {
        guard let record else { throw VaultCloudError.unavailable }
        let directory = FileManager.default.temporaryDirectory.appending(path: "CloudVault-Test-" + UUID().uuidString)
        try LocalVaultStorage.prepareDirectory(directory)
        let file = directory.appending(path: "backup")
        try record.archive.write(to: file)
        return CloudVaultDownload(url: file, metadata: record.metadata, recoveryEnvelope: record.recovery)
    }
}
