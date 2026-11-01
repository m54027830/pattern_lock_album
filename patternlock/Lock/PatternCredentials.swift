import CommonCrypto
import Foundation
import Security

nonisolated struct PatternCredential: Codable, Sendable {
    var version = 1
    let salt: Data
    let verifier: Data
    let rounds: UInt32
    var failedAttempts = 0
    var retryAfter: Date?
}

nonisolated enum PatternCredentialError: LocalizedError, Equatable {
    case inaccessible, invalid, alreadyRegistered, noPattern, invalidPattern, derivationFailed, duplicatePattern, invalidVaultName, duplicateVaultName
    var errorDescription: String? {
        switch self {
        case .inaccessible: "Your pattern couldn’t be accessed securely. Unlock your device and try again."
        case .invalid: "Your saved lock couldn’t be read. Your library remains locked."
        case .alreadyRegistered: "A pattern is already registered. Use your saved pattern to unlock."
        case .noPattern: "Set up a pattern before unlocking your library."
        case .invalidPattern: "Connect at least 4 different dots."
        case .derivationFailed: "Your pattern couldn’t be secured. Please try again."
        case .duplicatePattern: "That pattern already opens another vault. Choose a different pattern."
        case .invalidVaultName: "Give your vault a name between 1 and 40 characters."
        case .duplicateVaultName: "A vault with that name already exists. Choose a different name."
        }
    }
}

nonisolated protocol PatternCredentialStorage: Sendable {
    func read() throws -> Data?
    func create(_ data: Data) throws
    func update(_ data: Data) throws
}

nonisolated struct KeychainPatternStorage: PatternCredentialStorage {
    let service: String
    init(service: String = "jp.gm.patternlock.pattern-lock.v1") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "personal-library",
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PatternCredentialError.inaccessible }
        return data
    }

    func create(_ data: Data) throws {
        var query = query
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw PatternCredentialError.alreadyRegistered }
        guard status == errSecSuccess else { throw PatternCredentialError.inaccessible }
    }

    func update(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw PatternCredentialError.inaccessible }
    }
}

nonisolated struct PatternLockStatus: Sendable {
    let isRegistered: Bool
    let retryAfter: Date?
}

nonisolated enum PatternVerification: Equatable, Sendable {
    case accepted(Vault)
    case rejected(retryAfter: Date?)
}

nonisolated protocol PatternAuthenticating: Sendable {
    func status() async throws -> PatternLockStatus
    func register(_ nodes: [Int]) async throws -> Vault
    func createVault(name: String, pattern: [Int]) async throws -> Vault
    func verify(_ nodes: [Int], now: Date) async throws -> PatternVerification
}

nonisolated struct VaultCredential: Codable, Sendable {
    let vault: Vault
    let pattern: PatternCredential
}

nonisolated struct VaultRegistry: Codable, Sendable {
    var version = 2
    var vaults: [VaultCredential] = []
    var failedAttempts = 0
    var retryAfter: Date?
}

/// All vault credentials share one atomic Keychain record. The shared actor
/// serializes registration across windows without caching stale credentials.
actor PatternAuthenticator: PatternAuthenticating {
    static let shared = PatternAuthenticator()
    static let rounds: UInt32 = 600_000
    private let storage: any PatternCredentialStorage

    init(storage: any PatternCredentialStorage = KeychainPatternStorage()) { self.storage = storage }

    func status() throws -> PatternLockStatus {
        let registry = try read()
        return PatternLockStatus(isRegistered: registry != nil, retryAfter: registry?.retryAfter)
    }

    @discardableResult
    func register(_ nodes: [Int]) throws -> Vault {
        guard PatternRules.isValid(nodes) else { throw PatternCredentialError.invalidPattern }
        guard try read() == nil else { throw PatternCredentialError.alreadyRegistered }
        let credential = try makeCredential(nodes)
        let registry = VaultRegistry(vaults: [VaultCredential(vault: .personal, pattern: credential)])
        try storage.create(JSONEncoder().encode(registry))
        return .personal
    }

    func createVault(name: String, pattern: [Int]) throws -> Vault {
        guard PatternRules.isValid(pattern) else { throw PatternCredentialError.invalidPattern }
        guard var registry = try read() else { throw PatternCredentialError.noPattern }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw PatternCredentialError.invalidVaultName }
        guard !registry.vaults.contains(where: { $0.vault.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw PatternCredentialError.duplicateVaultName
        }
        guard try matchingVault(pattern, in: registry) == nil else { throw PatternCredentialError.duplicatePattern }
        let vault = Vault(id: UUID().uuidString, name: name)
        registry.vaults.append(VaultCredential(vault: vault, pattern: try makeCredential(pattern)))
        try storage.update(JSONEncoder().encode(registry))
        return vault
    }

    func verify(_ nodes: [Int], now: Date = Date()) throws -> PatternVerification {
        guard var registry = try read() else { throw PatternCredentialError.noPattern }
        if let retryAfter = registry.retryAfter, retryAfter > now { return .rejected(retryAfter: retryAfter) }
        guard PatternRules.isValid(nodes) else { throw PatternCredentialError.invalidPattern }
        if let vault = try matchingVault(nodes, in: registry) {
            registry.failedAttempts = 0
            registry.retryAfter = nil
            try storage.update(JSONEncoder().encode(registry))
            return .accepted(vault)
        }
        registry.failedAttempts = min(registry.failedAttempts + 1, 20)
        registry.retryAfter = registry.failedAttempts < 5 ? nil : now.addingTimeInterval(min(300, 30 * pow(2, Double(registry.failedAttempts - 5))))
        try storage.update(JSONEncoder().encode(registry))
        return .rejected(retryAfter: registry.retryAfter)
    }

    private func makeCredential(_ nodes: [Int]) throws -> PatternCredential {
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PatternCredentialError.derivationFailed }
        return PatternCredential(salt: salt, verifier: try derive(nodes, salt: salt, rounds: Self.rounds), rounds: Self.rounds)
    }

    private func matchingVault(_ nodes: [Int], in registry: VaultRegistry) throws -> Vault? {
        var match: Vault?
        // Evaluate every verifier, rather than stopping early for one vault.
        for entry in registry.vaults {
            let candidate = try derive(nodes, salt: entry.pattern.salt, rounds: entry.pattern.rounds)
            if constantTimeEqual(candidate, entry.pattern.verifier) { match = entry.vault }
        }
        return match
    }

    private func read() throws -> VaultRegistry? {
        guard let data = try storage.read() else { return nil }
        let decoder = JSONDecoder()
        if let registry = try? decoder.decode(VaultRegistry.self, from: data) {
            guard registry.version == 2, !registry.vaults.isEmpty,
                  (0...20).contains(registry.failedAttempts),
                  Set(registry.vaults.map { $0.vault.id }).count == registry.vaults.count,
                  registry.vaults.allSatisfy({ entry in
                      (entry.vault.id == Vault.personal.id || UUID(uuidString: entry.vault.id) != nil)
                          && !entry.vault.name.isEmpty && entry.vault.name.count <= 40
                          && valid(entry.pattern)
                  }) else { throw PatternCredentialError.invalid }
            return registry
        }
        // Upgrade the original single-pattern record atomically, retaining its
        // verifier, cooldown, and the existing Vaults/Personal media directory.
        guard let legacy = try? decoder.decode(PatternCredential.self, from: data), valid(legacy) else {
            throw PatternCredentialError.invalid
        }
        let migrated = VaultRegistry(vaults: [VaultCredential(vault: .personal, pattern: legacy)], failedAttempts: legacy.failedAttempts, retryAfter: legacy.retryAfter)
        try storage.update(JSONEncoder().encode(migrated))
        return migrated
    }

    private func valid(_ value: PatternCredential) -> Bool {
        value.version == 1 && value.salt.count == 32 && value.verifier.count == 32
            && value.rounds == Self.rounds && (0...20).contains(value.failedAttempts)
    }

    private func derive(_ nodes: [Int], salt: Data, rounds: UInt32) throws -> Data {
        // Each node uses one byte, so e.g. [1, 23] can never alias [12, 3].
        let password = nodes.map(UInt8.init)
        var output = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { password in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress!.assumingMemoryBound(to: Int8.self), password.count, salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &output, output.count)
            }
        }
        guard status == kCCSuccess else { throw PatternCredentialError.derivationFailed }
        return Data(output)
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}
