import Foundation
import Observation

nonisolated enum VaultEvents {
    static let duressActivated = Notification.Name("PatternDuressActivated")
    static let accessRevoked = Notification.Name("PatternVaultAccessRevoked")
}

nonisolated struct Vault: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String

    /// Keeps the pre-vault library in place during migration.
    static let personal = Vault(id: "Personal", name: "Personal")

    var root: URL { root(in: URL.applicationSupportDirectory.appending(path: "Vaults")) }
    func root(in directory: URL) -> URL { directory.appending(path: id, directoryHint: .isDirectory) }
}

/// Retains one repository per vault so an in-flight import remains attached to
/// its original vault when the user locks or switches libraries.
@MainActor @Observable final class VaultLibraries {
    static let shared = VaultLibraries()
    @ObservationIgnored private var stores: [String: LibraryStore] = [:]
    private let directory: URL
    private let security: VaultSecurityState

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Vaults"), security: VaultSecurityState = .shared) { self.directory = directory; self.security = security }

    func store(for vault: Vault) -> LibraryStore {
        if let existing = stores[vault.id] { return existing }
        let store = LibraryStore(root: vault.root(in: directory), security: security)
        stores[vault.id] = store
        return store
    }

    func dismissPresentations() {
        stores.values.forEach { $0.finishExport(); $0.dismissImportSummary() }
    }

    func applyDuress(_ activation: DuressActivation) {
        dismissPresentations()
        for id in activation.revokedVaultIDs {
            stores[id]?.invalidateDeletedVault()
            stores.removeValue(forKey: id)
        }
    }

    func forget(_ vault: Vault) {
        stores[vault.id]?.invalidateDeletedVault()
        stores.removeValue(forKey: vault.id)
    }
}
