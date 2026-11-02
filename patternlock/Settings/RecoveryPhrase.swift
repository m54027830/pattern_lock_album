import CommonCrypto
import CryptoKit
import Foundation
import Security

nonisolated enum VaultSettingsError: LocalizedError {
    case missingVault, wrongPattern, cooldown(Date), invalidPhrase, wrongPhrase, duplicatePhrase, noRecovery, invalidBackup, backupVersion, invalidName, busy, backupsDisabled

    var errorDescription: String? {
        switch self {
        case .missingVault: "This vault is no longer available."
        case .wrongPattern: "That isn’t this vault’s current pattern."
        case .cooldown(let date): "Too many attempts. Try again in \(max(1, Int(ceil(date.timeIntervalSinceNow)))) seconds."
        case .invalidPhrase: "Use at least 8 words and 40 characters, up to 1,024 characters. A generated phrase is recommended."
        case .wrongPhrase: "The recovery phrase didn’t match."
        case .duplicatePhrase: "That recovery phrase is already used by another vault. Choose a different phrase."
        case .noRecovery: "Set up a recovery phrase first. Keep it somewhere safe outside this app."
        case .invalidBackup: "The backup couldn’t be opened. Check the phrase and make sure the file is complete and unchanged."
        case .backupVersion: "This backup format isn’t supported by this version of Pattern."
        case .invalidName: "Give the vault a unique name between 1 and 40 characters."
        case .backupsDisabled: "Backups are turned off on this device after a duress unlock."
        case .busy: "Wait for the current operation to finish."
        }
    }
}

nonisolated struct RecoveryCredential: Codable, Sendable {
    let salt: Data
    let verifier: Data
    let rounds: UInt32
}

nonisolated enum RecoveryPhrase {
    static let rounds: UInt32 = 600_000

    // 128 distinct words; twenty uniformly selected words provide 140 random bits.
    static let words = """
    acorn amber anchor apple apron arrow atlas autumn bamboo beach beacon berry birch blossom blue breeze
    bridge brook brush cabin cactus candle canyon cedar cherry circle clay cloud clover coast cocoa coral
    cotton creek crystal daisy dawn deer delta dune eagle earth echo elm ember falcon feather fern
    field finch flame flower forest fox frost garden glacier gold granite grape grass green grove harbor
    hawk hazel hill honey horizon island ivory jade jasmine jewel juniper kite lake lantern leaf lemon
    lilac lily lime linen maple marble meadow mint moon moss mountain nest oak ocean olive opal
    orange orchid otter owl palm paper peach pearl pebble pine plum pond poppy quartz rain raven
    reed river robin rose ruby sage sand shell sky snow sparrow spring star stone sun willow
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    static func generate() throws -> String {
        guard words.count == 128, Set(words).count == 128 else { throw PatternCredentialError.derivationFailed }
        return try randomData(count: 20).map { words[Int($0) & 127] }.joined(separator: " ")
    }

    static func normalized(_ phrase: String) -> String {
        phrase.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func validate(_ phrase: String) throws {
        let value = normalized(phrase)
        guard (40...1_024).contains(value.count), value.split(separator: " ").count >= 8 else { throw VaultSettingsError.invalidPhrase }
    }

    static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PatternCredentialError.derivationFailed }
        return data
    }

    static func key(phrase: String, salt: Data) throws -> Data {
        let password = Array(normalized(phrase).utf8)
        guard !password.isEmpty, password.count <= 8_192, salt.count == 32 else { throw VaultSettingsError.invalidPhrase }
        var result = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { password in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress!.assumingMemoryBound(to: Int8.self), password.count, salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &result, result.count)
            }
        }
        guard status == kCCSuccess else { throw PatternCredentialError.derivationFailed }
        return Data(result)
    }

    static func credential(for phrase: String) throws -> RecoveryCredential {
        try validate(phrase)
        let salt = try randomData(count: 32)
        return RecoveryCredential(salt: salt, verifier: try key(phrase: phrase, salt: salt), rounds: rounds)
    }

    static func matches(_ phrase: String, credential: RecoveryCredential) throws -> Bool {
        guard credential.rounds == rounds, credential.salt.count == 32, credential.verifier.count == 32 else { throw PatternCredentialError.invalid }
        let candidate = try key(phrase: phrase, salt: credential.salt)
        return zip(candidate, credential.verifier).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
