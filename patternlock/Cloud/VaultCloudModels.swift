import CryptoKit
import Foundation

nonisolated enum VaultCloudError: LocalizedError {
    case signedOut, accountChanged, invalidPhrase, unavailable, invalidData, readOnly, exportDisabled, expired, openLimit, duplicateShare, cloudStopped
    var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "Sign in to iCloud in iPhone Settings to continue.")
        case .accountChanged: String(localized: "Sign in to the Apple Account used to set up this vault’s cloud access.")
        case .invalidPhrase: String(localized: "This sharing phrase couldn’t be opened. Check every word and ask the owner whether access is still available.")
        case .unavailable: String(localized: "This shared vault is unavailable. It may have been claimed by another Apple Account or revoked by its owner.")
        case .invalidData: String(localized: "The encrypted cloud data couldn’t be verified. Your local files have been kept.")
        case .readOnly: String(localized: "Only the owner can change a shared vault.")
        case .exportDisabled: String(localized: "The owner has turned off exporting from this shared vault.")
        case .expired: String(localized: "Access to this shared vault has expired.")
        case .openLimit: String(localized: "This shared vault has reached its open limit.")
        case .duplicateShare: String(localized: "This shared vault is already on this device. Use its pattern to open it.")
        case .cloudStopped: String(localized: "Cloud backup and sharing are stopped on this device after a duress unlock.")
        }
    }
}

nonisolated struct VaultSharePolicy: Codable, Equatable, Sendable {
    var expiresAt: Date?
    var maximumOpens: Int?
    var allowsExport = true
    var blocksCapture = false

    func check(opens: Int, now: Date = .now) throws {
        if let expiresAt, expiresAt <= now { throw VaultCloudError.expired }
        if let maximumOpens, opens >= maximumOpens { throw VaultCloudError.openLimit }
    }
}

nonisolated struct CloudEnvelope: Codable, Equatable, Sendable {
    let version: Int
    let salt: Data
    let ciphertext: Data
}

nonisolated struct CloudBackupConfiguration: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    let accountID: String
    let secret: String
    var recoveryEnvelope: CloudEnvelope
    var lastCompleted: Date?
    var lastDigest: Data?
}

nonisolated struct OwnedVaultShare: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    let accountID: String
    let secret: String
    let invitationID: String
    let label: String
    let policy: VaultSharePolicy
    var invitationReady = false
    var lastCompleted: Date?
    var lastDigest: Data?
    var zoneName: String { "Share-" + id }
    var deletion: CloudDeletion { CloudDeletion(accountID: accountID, recordID: invitationID, zoneName: zoneName) }
}

nonisolated struct JoinedVaultShare: Codable, Equatable, Sendable {
    let accountID: String
    let zoneName: String
    let ownerName: String
    let secret: String
    var policy: VaultSharePolicy
    var opens = 0
    var version: String?
}

nonisolated struct CloudDeletion: Codable, Equatable, Identifiable, Sendable {
    var id: String { accountID + ":" + (zoneName ?? recordID) }
    let accountID: String
    let recordID: String
    // nil deletes a private backup; otherwise revoke the zone and its public invitation.
    let zoneName: String?
}

nonisolated struct CloudBackupSummary: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
}

nonisolated struct CloudVaultMetadata: Codable, Sendable {
    let version: String
    let name: String
    let digest: Data
    var policy: VaultSharePolicy?
}

nonisolated struct CloudInvitation: Codable, Sendable {
    let url: URL
    let secret: String
    let zoneName: String
}

nonisolated final class CloudVaultDownload: Sendable {
    let url: URL
    let metadata: Data
    let recoveryEnvelope: CloudEnvelope?
    init(url: URL, metadata: Data, recoveryEnvelope: CloudEnvelope?) {
        self.url = url; self.metadata = metadata; self.recoveryEnvelope = recoveryEnvelope
    }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// Distinct domains prevent recovery, invitation lookup and metadata keys from
/// being interchangeable. Only generated 140-bit phrases are used for invitations.
nonisolated enum VaultCloudCrypto {
    static func invitationID(_ phrase: String) throws -> String {
        let normalized = RecoveryPhrase.normalized(phrase)
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count == 20, words.allSatisfy(RecoveryPhrase.words.contains) else { throw VaultCloudError.invalidPhrase }
        return "Invite-" + SHA256.hash(data: Data(("Pattern sharing lookup v1\n" + normalized).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func wrap<T: Encodable>(_ value: T, phrase: String, context: String) throws -> CloudEnvelope {
        try RecoveryPhrase.validate(phrase)
        let salt = try RecoveryPhrase.randomData(count: 32)
        let key = SymmetricKey(data: try RecoveryPhrase.key(phrase: phrase, salt: salt))
        let box = try AES.GCM.seal(JSONEncoder().encode(value), using: key, authenticating: Data(context.utf8))
        guard let ciphertext = box.combined else { throw VaultCloudError.invalidData }
        return CloudEnvelope(version: 1, salt: salt, ciphertext: ciphertext)
    }

    static func unwrap<T: Decodable>(_ type: T.Type, envelope: CloudEnvelope, phrase: String, context: String) throws -> T {
        guard envelope.version == 1, envelope.salt.count == 32, envelope.ciphertext.count < 65_536 else { throw VaultCloudError.invalidData }
        let key = SymmetricKey(data: try RecoveryPhrase.key(phrase: phrase, salt: envelope.salt))
        do {
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: key, authenticating: Data(context.utf8))
            return try JSONDecoder().decode(type, from: data)
        } catch { throw VaultCloudError.invalidData }
    }

    static func sealMetadata(_ value: CloudVaultMetadata, secret: String, context: String) throws -> Data {
        let key = metadataKey(secret)
        guard let data = try AES.GCM.seal(JSONEncoder().encode(value), using: key, authenticating: Data(context.utf8)).combined else { throw VaultCloudError.invalidData }
        return data
    }

    static func openMetadata(_ data: Data, secret: String, context: String) throws -> CloudVaultMetadata {
        guard data.count < 65_536 else { throw VaultCloudError.invalidData }
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: metadataKey(secret), authenticating: Data(context.utf8))
            return try JSONDecoder().decode(CloudVaultMetadata.self, from: plain)
        } catch { throw VaultCloudError.invalidData }
    }

    static func digest(name: String, snapshot: LibrarySnapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: Data(name.utf8) + (try encoder.encode(snapshot))))
    }

    private static func metadataKey(_ secret: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)), salt: Data("Pattern cloud metadata v1".utf8), info: Data(), outputByteCount: 32)
    }
}
