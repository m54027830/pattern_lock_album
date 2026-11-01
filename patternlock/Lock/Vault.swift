import Foundation
import Observation

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
    @ObservationIgnored private var stores: [String: LibraryStore] = [:]
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Vaults")) { self.directory = directory }

    func store(for vault: Vault) -> LibraryStore {
        if let existing = stores[vault.id] { return existing }
        let store = LibraryStore(root: vault.root(in: directory))
        stores[vault.id] = store
        return store
    }

    func dismissExports() { stores.values.forEach { $0.finishExport() } }
}
