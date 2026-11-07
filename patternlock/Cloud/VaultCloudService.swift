import Foundation
import Observation

@MainActor @Observable final class SharedVaultSession {
    let id = UUID()
    var error: String?
}

@MainActor @Observable final class VaultCloudService {
    static let shared = VaultCloudService()
    private(set) var busyVaults: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var deletionError: String?
    private var deletionTask: Task<Void, Never>?
    @ObservationIgnored private var viewingTasks: [UUID: (scope: UUID, task: Task<Void, Never>)] = [:]
    private let accessCheckInterval: Duration
    let transport: any VaultCloudTransport
    let authenticator: PatternAuthenticator
    init(transport: any VaultCloudTransport = CloudKitVaultTransport(), authenticator: PatternAuthenticator = .shared, accessCheckInterval: Duration = .seconds(30)) {
        self.transport = transport; self.authenticator = authenticator; self.accessCheckInterval = accessCheckInterval
    }

    func enableBackup(vault: Vault, store: LibraryStore, phrase: String) async throws {
        guard !busyVaults.contains(vault.id) else { throw VaultSettingsError.busy }
        busyVaults.insert(vault.id)
        defer { busyVaults.remove(vault.id); Task { await processDeletions() } }
        guard try await authenticator.settings(for: vault.id).cloudBackup == nil else { throw VaultSettingsError.busy }
        let account = try await transport.accountID()
        let secret = try RecoveryPhrase.generate()
        let id = UUID().uuidString
        let envelope = try await Task.detached {
            try VaultCloudCrypto.wrap(secret, phrase: phrase, context: "backup:" + id)
        }.value
        let configuration = CloudBackupConfiguration(id: id, accountID: account, secret: secret, recoveryEnvelope: envelope)
        try await authenticator.configureCloudBackup(vaultID: vault.id, configuration: configuration, phrase: phrase)
        busyVaults.remove(vault.id)
        try await synchronize(vault: vault, store: store, force: true)
    }

    func synchronize(vault: Vault, store: LibraryStore, force: Bool = false) async throws {
        guard !busyVaults.contains(vault.id), store.isLoaded, !store.isBusy else { return }
        busyVaults.insert(vault.id)
        defer { busyVaults.remove(vault.id); Task { await processDeletions() } }
        let entry = try await authenticator.settings(for: vault.id)
        guard entry.joinedShare == nil, entry.cloudBackup != nil || !(entry.ownedShares ?? []).isEmpty else { return }
        let lease = try authenticator.security.lease(for: vault.id)
        try authenticator.security.check(lease, forBackup: true)
        errors[vault.id] = nil
        do {
            let account = try await transport.accountID()
            try await store.withExclusiveAccess {
                let digest = try VaultCloudCrypto.digest(name: vault.name, snapshot: store.snapshot)
                if let backup = entry.cloudBackup, force || backup.lastDigest != digest {
                    guard backup.accountID == account else { throw VaultCloudError.accountChanged }
                    let metadata = CloudVaultMetadata(version: UUID().uuidString, name: vault.name, digest: digest)
                    let data = try VaultCloudCrypto.sealMetadata(metadata, secret: backup.secret, context: "backup:" + backup.id)
                    let archive = try await self.archive(vault: vault, store: store, secret: backup.secret)
                    defer { self.removeArchive(archive) }
                    try self.authenticator.security.check(lease, forBackup: true)
                    try await self.transport.uploadBackup(id: backup.id, archive: archive, metadata: data, recovery: backup.recoveryEnvelope)
                    try self.authenticator.security.check(lease, forBackup: true)
                    try await self.authenticator.completeCloudBackup(vaultID: vault.id, id: backup.id, envelope: backup.recoveryEnvelope, digest: digest)
                }
                for share in entry.ownedShares ?? [] {
                    if !share.invitationReady {
                        try await self.authenticator.revokeShare(vaultID: vault.id, id: share.id)
                        continue
                    }
                    guard force || share.lastDigest != digest || (share.policy.expiresAt.map { $0 <= .now } ?? false) else { continue }
                    try self.authenticator.security.check(lease, forBackup: true)
                    guard share.accountID == account else { throw VaultCloudError.accountChanged }
                    if let expires = share.policy.expiresAt, expires <= .now {
                        try await self.authenticator.revokeShare(vaultID: vault.id, id: share.id)
                        continue
                    }
                    try await self.publish(vault: vault, store: store, share: share, digest: digest, lease: lease)
                }
            }
        } catch {
            if !(error is CancellationError) { errors[vault.id] = error.localizedDescription }
            throw error
        }
        await processDeletions()
    }

    func createShare(vault: Vault, store: LibraryStore, label: String, policy: VaultSharePolicy) async throws -> String {
        guard !busyVaults.contains(vault.id) else { throw VaultSettingsError.busy }
        guard authenticator.purchaseAccess.isUnlimited else { throw FreeTierLimit.albums }
        busyVaults.insert(vault.id)
        defer { busyVaults.remove(vault.id); Task { await processDeletions() } }
        let account = try await transport.accountID()
        let phrase = try RecoveryPhrase.generate()
        let share = OwnedVaultShare(accountID: account, secret: try RecoveryPhrase.generate(), invitationID: try VaultCloudCrypto.invitationID(phrase), label: String(label.prefix(60)), policy: policy)
        let lease = try authenticator.security.lease(for: vault.id)
        try authenticator.security.check(lease, forBackup: true)
        // The durable intent precedes every network write. Duress/deletion can
        // queue revocation even if the first upload is interrupted.
        try await authenticator.addOwnedShare(vaultID: vault.id, share: share)
        do {
            try await store.withExclusiveAccess {
                let digest = try VaultCloudCrypto.digest(name: vault.name, snapshot: store.snapshot)
                try await self.publish(vault: vault, store: store, share: share, digest: digest, lease: lease)
                try self.authenticator.security.check(lease, forBackup: true)
                let url = try await self.transport.createInvitation(zone: share.zoneName)
                let invitation = CloudInvitation(url: url, secret: share.secret, zoneName: share.zoneName)
                let envelope = try await Task.detached {
                    try VaultCloudCrypto.wrap(invitation, phrase: phrase, context: share.invitationID)
                }.value
                try self.authenticator.security.check(lease, forBackup: true)
                try await self.transport.publishInvitation(id: share.invitationID, envelope: envelope)
                try self.authenticator.security.check(lease, forBackup: true)
                try await self.authenticator.markInvitationReady(vaultID: vault.id, shareID: share.id)
            }
            return phrase
        } catch {
            try? await authenticator.revokeShare(vaultID: vault.id, id: share.id)
            await processDeletions()
            throw error
        }
    }

    func revoke(vaultID: String, shareID: String) async throws {
        guard !busyVaults.contains(vaultID) else { throw VaultSettingsError.busy }
        try await authenticator.revokeShare(vaultID: vaultID, id: shareID)
        await processDeletions()
    }

    func disableBackup(vaultID: String) async throws {
        guard !busyVaults.contains(vaultID) else { throw VaultSettingsError.busy }
        try await authenticator.disableCloudBackup(vaultID: vaultID)
        await processDeletions()
    }

    func processDeletions() async {
        guard busyVaults.isEmpty else { return }
        if let deletionTask { await deletionTask.value; return }
        let task = Task { await self.performDeletions() }
        deletionTask = task
        await task.value
        deletionTask = nil
    }

    private func performDeletions() async {
        do {
            let pending = try await authenticator.pendingCloudDeletions()
            guard !pending.isEmpty else { deletionError = nil; return }
            let account = try await transport.accountID()
            for deletion in pending {
                try Task.checkCancellation()
                guard deletion.accountID == account else { throw VaultCloudError.accountChanged }
                try await transport.delete(deletion)
                try await authenticator.completeCloudDeletion(deletion)
            }
            deletionError = nil
        } catch { deletionError = error.localizedDescription }
    }

    func listBackups() async throws -> [CloudBackupSummary] {
        _ = try await transport.accountID()
        return try await transport.backups()
    }

    func prepareBackup(id: String, phrase: String) async throws -> PreparedVaultRestore {
        _ = try await transport.accountID()
        let download = try await transport.downloadBackup(id: id)
        guard let envelope = download.recoveryEnvelope else { throw VaultCloudError.invalidData }
        let secret = try await Task.detached {
            try VaultCloudCrypto.unwrap(String.self, envelope: envelope, phrase: phrase, context: "backup:" + id)
        }.value
        return try await prepare(download, secret: secret, context: "backup:" + id).prepared
    }

    func prepareJoin(phrase: String) async throws -> (prepared: PreparedVaultRestore, joined: JoinedVaultShare) {
        guard !authenticator.security.backupsDisabled else { throw VaultCloudError.cloudStopped }
        let account = try await transport.accountID()
        let id = try VaultCloudCrypto.invitationID(phrase)
        let envelope = try await transport.invitation(id: id)
        let invitation = try await Task.detached {
            try VaultCloudCrypto.unwrap(CloudInvitation.self, envelope: envelope, phrase: phrase, context: id)
        }.value
        try Task.checkCancellation()
        let location = try await transport.acceptInvitation(invitation.url, expectedZone: invitation.zoneName)
        let download = try await transport.downloadShare(zone: location.zone, owner: location.owner)
        let result = try await prepare(download, secret: invitation.secret, context: location.zone)
        guard let policy = result.metadata.policy else { throw VaultCloudError.invalidData }
        try policy.check(opens: 0)
        let joined = JoinedVaultShare(accountID: account, zoneName: location.zone, ownerName: location.owner, secret: invitation.secret, policy: policy, version: result.metadata.version)
        return (result.prepared, joined)
    }

    /// Opening is online-only: never expose a cached copy before checking Apple's
    /// share ACL and the encrypted policy. Transient errors keep the vault closed.
    func openShared(vault: Vault, store: LibraryStore) async throws -> JoinedVaultShare? {
        let entry = try await authenticator.settings(for: vault.id)
        guard let joined = entry.joinedShare else { return nil }
        guard !authenticator.security.backupsDisabled else { throw VaultCloudError.cloudStopped }
        guard try await transport.accountID() == joined.accountID else { throw VaultCloudError.accountChanged }
        var metadata = try await checkShared(joined)
        try metadata.policy?.check(opens: joined.opens)
        await store.load()
        guard store.isLoaded else { throw LibraryError.unreadableLibrary }
        if metadata.version != joined.version {
            let download = try await transport.downloadShare(zone: joined.zoneName, owner: joined.ownerName)
            let result = try await prepare(download, secret: joined.secret, context: joined.zoneName)
            metadata = result.metadata
            try metadata.policy?.check(opens: joined.opens)
            try await store.replaceFromShare(result.prepared)
        }
        try Task.checkCancellation()
        try await authenticator.recordSharedOpen(vaultID: vault.id, metadata: metadata)
        return try await authenticator.settings(for: vault.id).joinedShare
    }

    func checkShared(_ joined: JoinedVaultShare) async throws -> CloudVaultMetadata {
        guard !authenticator.security.backupsDisabled else { throw VaultCloudError.cloudStopped }
        let data = try await transport.sharedMetadata(zone: joined.zoneName, owner: joined.ownerName)
        let metadata = try VaultCloudCrypto.openMetadata(data, secret: joined.secret, context: joined.zoneName)
        guard let policy = metadata.policy else { throw VaultCloudError.invalidData }
        if let expiry = policy.expiresAt, expiry <= .now { throw VaultCloudError.expired }
        return metadata
    }

    // Owned by the app session, not a view's .task: presenting fullscreen video
    // must not suspend revocation/expiration checks for the obscured library.
    func monitor(_ joined: JoinedVaultShare, scope: UUID) -> SharedVaultSession {
        let session = SharedVaultSession()
        let task = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: accessCheckInterval)
                    _ = try await checkShared(joined)
                }
            } catch {
                if !Task.isCancelled { session.error = error.localizedDescription }
            }
        }
        viewingTasks[session.id] = (scope, task)
        return session
    }

    func stopViewingSessions(scope: UUID? = nil) {
        let ids = viewingTasks.filter { scope == nil || $0.value.scope == scope }.keys
        for id in ids { viewingTasks.removeValue(forKey: id)?.task.cancel() }
    }

    func stopViewingSession(_ session: SharedVaultSession?) {
        guard let session else { return }
        viewingTasks.removeValue(forKey: session.id)?.task.cancel()
    }

    private func prepare(_ download: CloudVaultDownload, secret: String, context: String) async throws -> (prepared: PreparedVaultRestore, metadata: CloudVaultMetadata) {
        let metadata = try VaultCloudCrypto.openMetadata(download.metadata, secret: secret, context: context)
        let prepared = try await VaultBackup.shared.prepareRestore(from: download.url, phrase: secret, security: authenticator.security)
        guard try VaultCloudCrypto.digest(name: prepared.name, snapshot: prepared.snapshot) == metadata.digest else { throw VaultCloudError.invalidData }
        return (prepared, metadata)
    }

    private func archive(vault: Vault, store: LibraryStore, secret: String) async throws -> URL {
        try await VaultBackup.shared.create(name: vault.name, snapshot: store.snapshot, root: store.repository.root, phrase: secret, security: authenticator.security)
    }

    private func publish(vault: Vault, store: LibraryStore, share: OwnedVaultShare, digest: Data, lease: VaultSecurityState.Lease) async throws {
        let metadata = CloudVaultMetadata(version: UUID().uuidString, name: vault.name, digest: digest, policy: share.policy)
        let data = try VaultCloudCrypto.sealMetadata(metadata, secret: share.secret, context: share.zoneName)
        let archive = try await archive(vault: vault, store: store, secret: share.secret)
        defer { removeArchive(archive) }
        try authenticator.security.check(lease, forBackup: true)
        try await transport.uploadShare(zone: share.zoneName, archive: archive, metadata: data)
        try authenticator.security.check(lease, forBackup: true)
        try await authenticator.completeShareUpload(vaultID: vault.id, id: share.id, digest: digest)
    }

    private func removeArchive(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
