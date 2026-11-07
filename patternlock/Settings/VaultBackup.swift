import CryptoKit
import Foundation

nonisolated final class PreparedVaultRestore: Sendable {
    let directory: URL
    let name: String
    let snapshot: LibrarySnapshot
    let lease: VaultSecurityState.Lease

    init(directory: URL, name: String, snapshot: LibrarySnapshot, lease: VaultSecurityState.Lease) {
        self.directory = directory; self.name = name; self.snapshot = snapshot; self.lease = lease
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// A bounded-memory, versioned archive. Every record authenticates the header
/// and its sequence number. An authenticated final marker detects truncation.
actor VaultBackup {
    static let shared = VaultBackup()
    private var cleanedTemporaryFiles = false
    private static let chunkSize = 1_048_576
    private static let magic = Data("PATTERN-BACKUP-1\n".utf8)

    private struct Header: Codable {
        let version: Int
        let salt: Data
        let rounds: UInt32
    }
    private struct Entry: Codable {
        let path: String
        let size: UInt64
    }
    private struct Manifest: Codable {
        let name: String
        let snapshot: LibrarySnapshot
        let files: [Entry]
    }

    func create(name: String, snapshot: LibrarySnapshot, root: URL, phrase: String, security: VaultSecurityState = .shared) throws -> URL {
        let lease = try security.lease(for: root.lastPathComponent)
        try security.check(lease, forBackup: true)
        try security.checkExport(root.lastPathComponent)
        cleanTemporaryFilesOnce()
        try RecoveryPhrase.validate(phrase)
        let directory = try temporaryDirectory(prefix: "EncryptedBackup-")
        let url = directory.appending(path: "Pattern-\(UUID().uuidString.prefix(8)).patternbackup")
        do {
            let files = try paths(for: snapshot).map { path in
                let source = root.appending(path: path)
                let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else { throw VaultSettingsError.invalidBackup }
                return Entry(path: path, size: UInt64(size))
            }
            let manifest = try JSONEncoder().encode(Manifest(name: name, snapshot: snapshot, files: files))
            guard manifest.count <= 8 * Self.chunkSize else { throw VaultSettingsError.invalidBackup }
            let header = Header(version: 1, salt: try RecoveryPhrase.randomData(count: 32), rounds: RecoveryPhrase.rounds)
            let headerData = try JSONEncoder().encode(header)
            let key = SymmetricKey(data: try RecoveryPhrase.key(phrase: phrase, salt: header.salt))
            let headerHash = Data(SHA256.hash(data: headerData))
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            try output.write(contentsOf: Self.magic)
            try writePacket(headerData, to: output)
            var sequence: UInt64 = 0
            try writeRecord(manifest, to: output, key: key, headerHash: headerHash, sequence: &sequence)
            for entry in files {
                try security.check(lease, forBackup: true)
                let input = try FileHandle(forReadingFrom: root.appending(path: entry.path))
                defer { try? input.close() }
                var remaining = entry.size
                while remaining > 0 {
                    try security.check(lease, forBackup: true)
                    let data = try readExactly(Int(min(remaining, UInt64(Self.chunkSize))), from: input)
                    try writeRecord(data, to: output, key: key, headerHash: headerHash, sequence: &sequence)
                    remaining -= UInt64(data.count)
                }
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw VaultSettingsError.invalidBackup }
            }
            try writeRecord(Data("complete".utf8), to: output, key: key, headerHash: headerHash, sequence: &sequence)
            try output.synchronize()
            try security.check(lease, forBackup: true)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func prepareRestore(from url: URL, phrase: String, security: VaultSecurityState = .shared) throws -> PreparedVaultRestore {
        let lease = try security.lease(for: "Restore")
        cleanTemporaryFilesOnce()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Result<PreparedVaultRestore, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result { try self.readBackup(from: readableURL, phrase: phrase, security: security, lease: lease) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw VaultSettingsError.invalidBackup }
        return try result.get()
    }

    func cleanTemporaryFilesOnce() {
        guard !cleanedTemporaryFiles else { return }
        cleanedTemporaryFiles = true
        let files = FileManager.default
        guard let children = try? files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for url in children where url.lastPathComponent.hasPrefix("EncryptedBackup-") || url.lastPathComponent.hasPrefix("RestoringVault-") {
            try? files.removeItem(at: url)
        }
    }

    private func readBackup(from url: URL, phrase: String, security: VaultSecurityState, lease: VaultSecurityState.Lease) throws -> PreparedVaultRestore {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard try readExactly(Self.magic.count, from: input) == Self.magic else { throw VaultSettingsError.backupVersion }
        let headerData = try readPacket(from: input, maximum: 16_384)
        let header = try JSONDecoder().decode(Header.self, from: headerData)
        guard header.version == 1, header.rounds == RecoveryPhrase.rounds, header.salt.count == 32 else { throw VaultSettingsError.backupVersion }
        let key = SymmetricKey(data: try RecoveryPhrase.key(phrase: phrase, salt: header.salt))
        let headerHash = Data(SHA256.hash(data: headerData))
        var sequence: UInt64 = 0
        let manifestData = try readRecord(from: input, key: key, headerHash: headerHash, sequence: &sequence, maximum: 8 * Self.chunkSize + 28)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let expectedPaths = try paths(for: manifest.snapshot)
        guard !manifest.name.isEmpty, manifest.name.count <= 40,
              manifest.files.map(\.path) == expectedPaths else { throw VaultSettingsError.invalidBackup }
        let directory = try temporaryDirectory(prefix: "RestoringVault-")
        do {
            for subdirectory in ["Originals", "Thumbnails"] {
                try FileManager.default.createDirectory(at: directory.appending(path: subdirectory), withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            }
            for entry in manifest.files {
                try security.check(lease)
                let target = directory.appending(path: entry.path)
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var remaining = entry.size
                while remaining > 0 {
                    try security.check(lease)
                    let data = try readRecord(from: input, key: key, headerHash: headerHash, sequence: &sequence, maximum: Self.chunkSize + 28)
                    guard data.count == Int(min(remaining, UInt64(Self.chunkSize))) else { throw VaultSettingsError.invalidBackup }
                    try output.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                }
                try output.synchronize()
            }
            let end = try readRecord(from: input, key: key, headerHash: headerHash, sequence: &sequence, maximum: 128)
            guard end == Data("complete".utf8), (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw VaultSettingsError.invalidBackup }
            try JSONEncoder().encode(manifest.snapshot).write(to: directory.appending(path: "library.json"), options: [.atomic, .completeFileProtection])
            try security.check(lease)
            return PreparedVaultRestore(directory: directory, name: manifest.name, snapshot: manifest.snapshot, lease: lease)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func install(_ prepared: PreparedVaultRestore, name: String, pattern: [Int], authenticator: PatternAuthenticator = .shared, directory: URL = URL.applicationSupportDirectory.appending(path: "Vaults")) async throws -> Vault {
        try Task.checkCancellation()
        let vault = Vault(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        // Keep the prepared copy until the Keychain commit succeeds, so retrying a
        // duplicate name/pattern doesn't require downloading and decrypting again.
        try await authenticator.installRestoredVault(vault, pattern: pattern, preparedDirectory: prepared.directory, directory: directory, lease: prepared.lease)
        try? FileManager.default.removeItem(at: prepared.directory)
        return vault
    }

    private func paths(for snapshot: LibrarySnapshot) throws -> [String] {
        guard snapshot.version == 1, snapshot.items.count <= 100_000,
              Set(snapshot.items.map(\.id)).count == snapshot.items.count,
              Set(snapshot.items.map(\.filename)).count == snapshot.items.count,
              Set(snapshot.folders.map(\.id)).count == snapshot.folders.count else { throw VaultSettingsError.invalidBackup }
        let folderIDs = Set(snapshot.folders.map(\.id))
        return try snapshot.items.flatMap { item in
            let filename = item.filename
            guard !filename.isEmpty, filename != ".", filename != "..", filename.utf8.count <= 255,
                  !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0"),
                  item.folderID == nil || folderIDs.contains(item.folderID!),
                  item.duration == nil || (item.duration!.isFinite && item.duration! >= 0) else { throw VaultSettingsError.invalidBackup }
            return ["Originals/" + filename, "Thumbnails/" + item.id.uuidString + ".jpg"]
        }
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var protectedDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        return directory
    }

    private func associatedData(_ headerHash: Data, sequence: UInt64) -> Data {
        var value = sequence.bigEndian
        return headerHash + withUnsafeBytes(of: &value) { Data($0) }
    }

    private func writeRecord(_ data: Data, to output: FileHandle, key: SymmetricKey, headerHash: Data, sequence: inout UInt64) throws {
        let sealed = try AES.GCM.seal(data, using: key, authenticating: associatedData(headerHash, sequence: sequence))
        guard let combined = sealed.combined else { throw VaultSettingsError.invalidBackup }
        try writePacket(combined, to: output)
        sequence += 1
    }

    private func readRecord(from input: FileHandle, key: SymmetricKey, headerHash: Data, sequence: inout UInt64, maximum: Int) throws -> Data {
        let encrypted = try readPacket(from: input, maximum: maximum)
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plain = try AES.GCM.open(box, using: key, authenticating: associatedData(headerHash, sequence: sequence))
            sequence += 1
            return plain
        } catch { throw VaultSettingsError.invalidBackup }
    }

    private func writePacket(_ data: Data, to output: FileHandle) throws {
        guard data.count <= Int(UInt32.max) else { throw VaultSettingsError.invalidBackup }
        var length = UInt32(data.count).bigEndian
        try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try output.write(contentsOf: data)
    }

    private func readPacket(from input: FileHandle, maximum: Int) throws -> Data {
        let prefix = try readExactly(4, from: input)
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximum else { throw VaultSettingsError.invalidBackup }
        return try readExactly(count, from: input)
    }

    private func readExactly(_ count: Int, from input: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty else { throw VaultSettingsError.invalidBackup }
            data.append(chunk)
        }
        return data
    }
}
