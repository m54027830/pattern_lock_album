import Foundation

/// Synchronous revocation checks cover work already running on another actor.
/// The Keychain registry is the durable source of this process-wide state.
nonisolated final class VaultSecurityState: @unchecked Sendable {
    static let shared = VaultSecurityState()
    private let lock = NSLock()
    private var revokedIDs: Set<String> = []
    private var backupStopped = false
    private var shareEpoch: UUID?

    struct Lease: Sendable {
        let vaultID: String
        fileprivate let epoch: UUID?
    }

    func update(from registry: VaultRegistry) {
        lock.withLock {
            revokedIDs = Set(registry.revokedVaultIDs ?? [])
            backupStopped = registry.backupsDisabled == true
            shareEpoch = registry.sharingEpoch
        }
    }

    var backupsDisabled: Bool { lock.withLock { backupStopped } }

    func allowsAccess(to vaultID: String) -> Bool {
        lock.withLock { !revokedIDs.contains(vaultID) }
    }

    func checkAccess(to vaultID: String) throws {
        guard allowsAccess(to: vaultID) else { throw VaultSettingsError.missingVault }
    }

    func lease(for vaultID: String) throws -> Lease {
        try lock.withLock {
            guard !revokedIDs.contains(vaultID) else { throw VaultSettingsError.missingVault }
            return Lease(vaultID: vaultID, epoch: shareEpoch)
        }
    }

    func check(_ lease: Lease, forBackup: Bool = false) throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard !revokedIDs.contains(lease.vaultID), lease.epoch == shareEpoch else { throw CancellationError() }
            if forBackup && backupStopped { throw VaultSettingsError.backupsDisabled }
        }
    }
}

nonisolated struct DuressActivation: Sendable {
    let revokedVaultIDs: Set<String>
}
