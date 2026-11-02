import CryptoKit
import Foundation

nonisolated protocol ResettablePatternCredentialStorage: PatternCredentialStorage {
    func remove() throws
}

/// The Keychain can outlive an uninstall. Its payload is therefore encrypted
/// with a random key in the app container, excluded from device backups.
/// Deleting the app removes that key; the next install discards the old payload.
nonisolated final class InstallationCredentialStorage: PatternCredentialStorage, @unchecked Sendable {
    private static let magic = Data("PATTERN-INSTALL-1\n".utf8)
    private let storage: any ResettablePatternCredentialStorage
    private let applicationSupport: URL
    private let lock = NSLock()
    private var key: SymmetricKey?
    private let files = FileManager.default

    init(storage: any ResettablePatternCredentialStorage = KeychainPatternStorage(),
         applicationSupport: URL = .applicationSupportDirectory) {
        self.storage = storage
        self.applicationSupport = applicationSupport
    }

    private var installationDirectory: URL { applicationSupport.appending(path: "Installation") }
    private var keyURL: URL { installationDirectory.appending(path: "credential-key") }
    private var vaultsDirectory: URL { applicationSupport.appending(path: "Vaults") }

    func read() throws -> Data? {
        try lock.withLock {
            let key = try prepare()
            guard let data = try storage.read() else { return nil }
            guard data.starts(with: Self.magic) else { throw PatternCredentialError.invalid }
            do {
                let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count))
                return try AES.GCM.open(box, using: key, authenticating: Self.magic)
            } catch { throw PatternCredentialError.invalid }
        }
    }

    func create(_ data: Data) throws {
        try lock.withLock { try storage.create(seal(data, key: prepare())) }
    }

    func update(_ data: Data) throws {
        try lock.withLock { try storage.update(seal(data, key: prepare())) }
    }

    private func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: Self.magic)
        guard let combined = box.combined else { throw PatternCredentialError.derivationFailed }
        return Self.magic + combined
    }

    /// Runs before every first credential access, including restore and cleanup.
    /// A failed read/write never marks initialization complete.
    private func prepare() throws -> SymmetricKey {
        if let key { return key }
        let previous = try storage.read() // A locked Keychain is not an empty one.
        let localKey: Data?
        do { localKey = try Data(contentsOf: keyURL) }
        catch CocoaError.fileReadNoSuchFile { localKey = nil }
        catch CocoaError.fileNoSuchFile { localKey = nil }

        let material: Data
        if let localKey {
            guard localKey.count == 32 else { throw PatternCredentialError.invalid }
            material = localKey
        } else {
            // Only the old, unbound format can migrate in place. Require local
            // library evidence so a leftover Keychain on reinstall cannot do so.
            let legacyInstall: Bool
            if let previous, !previous.starts(with: Self.magic) { legacyInstall = try hasLegacyLibrary() }
            else { legacyInstall = false }
            if !legacyInstall {
                try storage.remove()
                if files.fileExists(atPath: vaultsDirectory.path) { try files.removeItem(at: vaultsDirectory) }
            }
            material = try RecoveryPhrase.randomData(count: 32)
        }

        try LocalVaultStorage.prepareDirectory(installationDirectory)
        try LocalVaultStorage.prepareDirectory(vaultsDirectory)
        // Clear old explicit backup-inclusion flags during an in-place upgrade.
        for url in try files.contentsOfDirectory(at: vaultsDirectory, includingPropertiesForKeys: [.isDirectoryKey]) {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try LocalVaultStorage.excludeFromBackup(url)
            }
        }
        if localKey == nil {
            try material.write(to: keyURL, options: [.atomic, .completeFileProtection])
        }
        try LocalVaultStorage.excludeFromBackup(keyURL)
        let newKey = SymmetricKey(data: material)
        // Write the local key before migrating: an interrupted Keychain update
        // can retry with the same key and never loses an existing library.
        if let legacy = try storage.read(), !legacy.starts(with: Self.magic) {
            try storage.update(seal(legacy, key: newKey))
        }
        key = newKey
        return newKey
    }

    private func hasLegacyLibrary() throws -> Bool {
        guard files.fileExists(atPath: vaultsDirectory.path) else { return false }
        return try files.contentsOfDirectory(at: vaultsDirectory, includingPropertiesForKeys: [.isDirectoryKey]).contains { url in
            var id = url.lastPathComponent
            for prefix in ["InstallingVault-", "DeletingVault-"] where id.hasPrefix(prefix) { id.removeFirst(prefix.count) }
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            return (id == Vault.personal.id || UUID(uuidString: id) != nil) && isDirectory
        }
    }
}

nonisolated enum LocalVaultStorage {
    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        try excludeFromBackup(url)
    }

    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
