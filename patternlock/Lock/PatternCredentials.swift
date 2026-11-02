import CommonCrypto
import Foundation
import Security

nonisolated struct PatternCredential: Codable, Equatable, Sendable {
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
    var gridSize: Int = 5
}

nonisolated enum PatternVerification: Equatable, Sendable {
    case accepted(Vault)
    case requiresFaceID(FaceIDChallenge)
    case dummy(Vault)
    case rejected(retryAfter: Date?)
}

nonisolated protocol PatternAuthenticating: Sendable {
    func status() async throws -> PatternLockStatus
    func register(_ nodes: [Int]) async throws -> Vault
    func registerFirstVault(name: String, pattern: [Int], gridSize: Int, recoveryPhrase: String) async throws -> Vault
    func createVault(name: String, pattern: [Int]) async throws -> Vault
    func createVault(name: String, pattern: [Int], from vaultID: String) async throws -> Vault
    func verify(_ nodes: [Int], now: Date) async throws -> PatternVerification
    func completeFaceID(_ challenge: FaceIDChallenge, result: FaceIDResult) async throws -> PatternVerification
    func cancelFaceID(_ challenge: FaceIDChallenge) async
    nonisolated func accessIsAllowed(to vaultID: String) -> Bool
}

extension PatternAuthenticating {
    func registerFirstVault(name: String, pattern: [Int], gridSize: Int, recoveryPhrase: String) async throws -> Vault { throw PatternCredentialError.noPattern }
    func completeFaceID(_ challenge: FaceIDChallenge, result: FaceIDResult) async throws -> PatternVerification { throw VaultAccessError.changed }
    func cancelFaceID(_ challenge: FaceIDChallenge) async {}

    func createVault(name: String, pattern: [Int], from vaultID: String) async throws -> Vault {
        try await createVault(name: name, pattern: pattern)
    }
    nonisolated func accessIsAllowed(to vaultID: String) -> Bool { true }
}

nonisolated struct VaultCredential: Codable, Equatable, Sendable {
    var vault: Vault
    var pattern: PatternCredential
    var recovery: RecoveryCredential?
    var duressVaultID: String? // Read compatibility with the earlier decoy configuration.
    var isDuressVault: Bool?
    var requiresFaceID: Bool?
    var dummyVaultID: String?
    var pendingRecoveryPhrase: String? // Keychain-only, removed after the user saves it.
}

nonisolated struct VaultRegistry: Codable, Equatable, Sendable {
    var version = 2
    var gridSize: Int?
    var effectiveGridSize: Int { gridSize ?? 5 }
    var revokedVaultIDs: [String]?
    var backupsDisabled: Bool?
    var sharingEpoch: UUID?
    var vaults: [VaultCredential] = []
    var failedAttempts = 0
    var retryAfter: Date?
}

/// All vault credentials share one atomic Keychain record. The shared actor
/// serializes registration across windows without caching stale credentials.
actor PatternAuthenticator: PatternAuthenticating {
    static let shared = PatternAuthenticator(security: .shared)
    static let rounds: UInt32 = 600_000
    private let storage: any PatternCredentialStorage
    nonisolated let security: VaultSecurityState
    nonisolated let purchaseAccess: PurchaseAccess
    private let directory: URL
    private struct PendingFaceID {
        let vaultID: String
        let verifier: Data
        let dummyVaultID: String?
        let isDuressVault: Bool
        let lease: VaultSecurityState.Lease
        let expires: Date
    }
    private var faceIDChallenges: [UUID: PendingFaceID] = [:]

    init(storage: any PatternCredentialStorage = KeychainPatternStorage(),
         security: VaultSecurityState = VaultSecurityState(),
         purchaseAccess: PurchaseAccess = .shared,
         directory: URL = URL.applicationSupportDirectory.appending(path: "Vaults")) {
        self.storage = storage; self.security = security; self.purchaseAccess = purchaseAccess; self.directory = directory
    }

    nonisolated func accessIsAllowed(to vaultID: String) -> Bool { security.allowsAccess(to: vaultID) }

    func status() throws -> PatternLockStatus {
        let registry = try read()
        return PatternLockStatus(isRegistered: !(registry?.vaults.isEmpty ?? true), retryAfter: registry?.retryAfter, gridSize: registry?.effectiveGridSize ?? 5)
    }

    @discardableResult
    func register(_ nodes: [Int]) throws -> Vault {
        let existing = try read()
        guard PatternRules.isValid(nodes, gridSize: existing?.effectiveGridSize ?? 5) else { throw PatternCredentialError.invalidPattern }
        guard existing?.vaults.isEmpty ?? true else { throw PatternCredentialError.alreadyRegistered }
        let credential = try makeCredential(nodes)
        // Never reuse a deleted vault's directory if cleanup was interrupted.
        let vault = existing == nil ? Vault.personal : Vault(id: UUID().uuidString, name: "Personal")
        var registry = existing ?? VaultRegistry()
        registry.vaults = [VaultCredential(vault: vault, pattern: credential)]
        if existing == nil { try storage.create(JSONEncoder().encode(registry)) }
        else { try storage.update(JSONEncoder().encode(registry)) }
        return vault
    }

    func createVault(name: String, pattern: [Int], from vaultID: String) async throws -> Vault {
        _ = try settings(for: vaultID)
        return try createVault(name: name, pattern: pattern)
    }

    func createVault(name: String, pattern: [Int]) throws -> Vault {
        guard var registry = try read() else { throw PatternCredentialError.noPattern }
        guard PatternRules.isValid(pattern, gridSize: registry.effectiveGridSize) else { throw PatternCredentialError.invalidPattern }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw PatternCredentialError.invalidVaultName }
        guard !registry.vaults.contains(where: { $0.vault.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw PatternCredentialError.duplicateVaultName
        }
        guard try matchingVault(pattern, in: registry) == nil else { throw PatternCredentialError.duplicatePattern }
        try purchaseAccess.checkAlbumCreation(currentCount: registry.vaults.count)
        let vault = Vault(id: UUID().uuidString, name: name)
        registry.vaults.append(VaultCredential(vault: vault, pattern: try makeCredential(pattern)))
        try storage.update(JSONEncoder().encode(registry))
        return vault
    }

    func verify(_ nodes: [Int], now: Date = Date()) throws -> PatternVerification {
        guard var registry = try read() else { throw PatternCredentialError.noPattern }
        if let retryAfter = registry.retryAfter, retryAfter > now { return .rejected(retryAfter: retryAfter) }
        guard PatternRules.isValid(nodes, gridSize: registry.effectiveGridSize) else { throw PatternCredentialError.invalidPattern }
        if let vault = try matchingVault(nodes, in: registry) {
            registry.failedAttempts = 0
            registry.retryAfter = nil
            let entry = registry.vaults.first { $0.vault.id == vault.id }!
            // A missing dummy must never expose a Face ID-protected source.
            // In that case, authenticate before opening it or applying duress.
            if entry.isDuressVault == true && (entry.requiresFaceID != true || entry.dummyVaultID != nil) {
                let display = try activateDuress(vault, registry: &registry)
                return display.id == vault.id ? .accepted(display) : .dummy(display)
            }
            try storage.update(JSONEncoder().encode(registry))
            if entry.requiresFaceID == true {
                faceIDChallenges = faceIDChallenges.filter { $0.value.expires > Date() }
                let challenge = FaceIDChallenge(id: UUID(), vaultID: vault.id)
                faceIDChallenges[challenge.id] = PendingFaceID(vaultID: vault.id, verifier: entry.pattern.verifier,
                    dummyVaultID: entry.dummyVaultID, isDuressVault: entry.isDuressVault == true,
                    lease: try security.lease(for: vault.id), expires: Date().addingTimeInterval(120))
                return .requiresFaceID(challenge)
            }
            return .accepted(vault)
        }
        registry.failedAttempts = min(registry.failedAttempts + 1, 20)
        registry.retryAfter = registry.failedAttempts < 5 ? nil : now.addingTimeInterval(min(300, 30 * pow(2, Double(registry.failedAttempts - 5))))
        try storage.update(JSONEncoder().encode(registry))
        return .rejected(retryAfter: registry.retryAfter)
    }

    func cancelFaceID(_ challenge: FaceIDChallenge) async { faceIDChallenges.removeValue(forKey: challenge.id) }

    func completeFaceID(_ challenge: FaceIDChallenge, result: FaceIDResult) async throws -> PatternVerification {
        guard let pending = faceIDChallenges.removeValue(forKey: challenge.id), pending.vaultID == challenge.vaultID,
              pending.expires > Date(), var registry = try read(),
              let entry = registry.vaults.first(where: { $0.vault.id == pending.vaultID }),
              entry.requiresFaceID == true, (entry.isDuressVault == true) == pending.isDuressVault,
              entry.pattern.verifier == pending.verifier, entry.dummyVaultID == pending.dummyVaultID else { throw VaultAccessError.changed }
        try security.check(pending.lease)
        switch result {
        case .authenticated:
            if pending.isDuressVault { return .accepted(try activateDuress(entry.vault, registry: &registry)) }
            return .accepted(entry.vault)
        case .interrupted: throw VaultAccessError.interrupted
        case .failed:
            guard let id = entry.dummyVaultID, id != entry.vault.id,
                  let dummy = registry.vaults.first(where: { $0.vault.id == id }) else { throw VaultAccessError.invalidDummy }
            try security.checkAccess(to: id)
            // Display only. Do not verify the dummy's pattern, rotate recovery,
            // revoke credentials, disable backups, or emit a duress event.
            return .dummy(dummy.vault)
        }
    }

    func availableDummyVaults(for vaultID: String) throws -> [Vault] {
        guard let registry = try read(), registry.vaults.contains(where: { $0.vault.id == vaultID }) else { throw VaultSettingsError.missingVault }
        return registry.vaults.map(\.vault).filter { $0.id != vaultID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setAccessSettings(vaultID: String, requireFaceID: Bool, dummyVaultID: String?, currentPattern: [Int],
                           dummyPattern: [Int]?, faceID: any FaceIDAuthenticating) async throws {
        let original = try authorizedRegistry(vaultID: vaultID, pattern: currentPattern)
        let source = original.vaults.first { $0.vault.id == vaultID }!
        let sourceLease = try security.lease(for: vaultID)
        if requireFaceID && dummyVaultID == nil { throw VaultAccessError.chooseDummy }
        let target = original.vaults.first { $0.vault.id == dummyVaultID }
        if let dummyVaultID {
            guard dummyVaultID != vaultID, target != nil else { throw VaultAccessError.invalidDummy }
            if dummyVaultID != source.dummyVaultID {
                guard let dummyPattern else { throw VaultSettingsError.wrongPattern }
                _ = try authorizedRegistry(vaultID: dummyVaultID, pattern: dummyPattern)
            }
        }
        if source.requiresFaceID == true || requireFaceID || (target?.requiresFaceID == true && dummyVaultID != source.dummyVaultID) {
            guard await faceID.authenticate(reason: "Confirm Face ID to update vault access.") == .authenticated else { throw VaultAccessError.faceIDRequired }
        }
        try Task.checkCancellation()
        guard var registry = try read(), let index = registry.vaults.firstIndex(where: { $0.vault.id == vaultID }) else { throw VaultAccessError.changed }
        try security.check(sourceLease)
        let latest = registry.vaults[index]
        guard latest.pattern.verifier == source.pattern.verifier, latest.requiresFaceID == source.requiresFaceID,
              latest.dummyVaultID == source.dummyVaultID, latest.isDuressVault == source.isDuressVault else { throw VaultAccessError.changed }
        if let target {
            guard let current = registry.vaults.first(where: { $0.vault.id == target.vault.id }),
                  current.pattern.verifier == target.pattern.verifier, current.requiresFaceID == target.requiresFaceID else { throw VaultAccessError.changed }
        }
        registry.vaults[index].requiresFaceID = requireFaceID
        registry.vaults[index].dummyVaultID = dummyVaultID
        registry.failedAttempts = 0; registry.retryAfter = nil
        try storage.update(JSONEncoder().encode(registry))
        // Invalidate challenges issued before this configuration change.
        faceIDChallenges = faceIDChallenges.filter { $0.value.vaultID != vaultID }
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
        if var registry = try? decoder.decode(VaultRegistry.self, from: data) {
            guard registry.version == 2, PatternRules.supportedSizes.contains(registry.effectiveGridSize),
                  (0...20).contains(registry.failedAttempts),
                  (registry.revokedVaultIDs ?? []).allSatisfy({ $0 == Vault.personal.id || UUID(uuidString: $0) != nil }),
                  Set(registry.revokedVaultIDs ?? []).isDisjoint(with: registry.vaults.map { $0.vault.id }),
                  Set(registry.vaults.map { $0.vault.id }).count == registry.vaults.count,
                  registry.vaults.allSatisfy({ entry in
                      (entry.vault.id == Vault.personal.id || UUID(uuidString: entry.vault.id) != nil)
                          && !entry.vault.name.isEmpty && entry.vault.name.count <= 40
                          && valid(entry.pattern)
                          && (entry.recovery == nil || (entry.recovery?.rounds == RecoveryPhrase.rounds && entry.recovery?.salt.count == 32 && entry.recovery?.verifier.count == 32))
                          && (entry.dummyVaultID == nil || (entry.dummyVaultID != entry.vault.id && registry.vaults.contains { $0.vault.id == entry.dummyVaultID }))
                          && (entry.duressVaultID == nil || (entry.duressVaultID != entry.vault.id && registry.vaults.contains { $0.vault.id == entry.duressVaultID }))
                  }) else { throw PatternCredentialError.invalid }
            // A former decoy must not silently become destructive on upgrade.
            // Keep it as a normal vault until explicitly armed in settings.
            if registry.vaults.contains(where: { $0.duressVaultID != nil }) {
                for index in registry.vaults.indices { registry.vaults[index].duressVaultID = nil }
                try storage.update(JSONEncoder().encode(registry))
            }
            security.update(from: registry)
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

    func settings(for vaultID: String) throws -> VaultCredential {
        guard let entry = try read()?.vaults.first(where: { $0.vault.id == vaultID }) else { throw VaultSettingsError.missingVault }
        return entry
    }

    func renameVault(_ vaultID: String, name: String) throws -> Vault {
        guard var registry = try read(), let index = registry.vaults.firstIndex(where: { $0.vault.id == vaultID }) else { throw VaultSettingsError.missingVault }
        let name = try validatedName(name, in: registry, excluding: vaultID)
        let vault = Vault(id: vaultID, name: name)
        registry.vaults[index].vault = vault
        try storage.update(JSONEncoder().encode(registry))
        return vault
    }

    func changePattern(vaultID: String, current: [Int], replacement: [Int]) throws {
        var registry = try authorizedRegistry(vaultID: vaultID, pattern: current)
        guard PatternRules.isValid(replacement, gridSize: registry.effectiveGridSize) else { throw PatternCredentialError.invalidPattern }
        if let match = try matchingVault(replacement, in: registry), match.id != vaultID { throw PatternCredentialError.duplicatePattern }
        let index = registry.vaults.firstIndex { $0.vault.id == vaultID }!
        registry.vaults[index].pattern = try makeCredential(replacement)
        try Task.checkCancellation()
        try storage.update(JSONEncoder().encode(registry))
        NotificationCenter.default.post(name: VaultEvents.accessRevoked, object: vaultID)
    }

    func setRecoveryPhrase(vaultID: String, phrase: String, currentPattern: [Int]) throws {
        var registry = try authorizedRegistry(vaultID: vaultID, pattern: currentPattern)
        let credential = try RecoveryPhrase.credential(for: phrase)
        for entry in registry.vaults where entry.vault.id != vaultID {
            if let recovery = entry.recovery, try RecoveryPhrase.matches(phrase, credential: recovery) { throw VaultSettingsError.duplicatePhrase }
        }
        let index = registry.vaults.firstIndex { $0.vault.id == vaultID }!
        registry.vaults[index].recovery = credential
        registry.vaults[index].pendingRecoveryPhrase = nil
        try Task.checkCancellation()
        try storage.update(JSONEncoder().encode(registry))
    }

    func validateRecoveryPhrase(vaultID: String, phrase: String) throws {
        guard var registry = try read(), let entry = registry.vaults.first(where: { $0.vault.id == vaultID }) else { throw VaultSettingsError.missingVault }
        try checkCooldown(registry)
        guard let recovery = entry.recovery else { throw VaultSettingsError.noRecovery }
        guard try RecoveryPhrase.matches(phrase, credential: recovery) else { try recordFailure(&registry); throw VaultSettingsError.wrongPhrase }
        registry.failedAttempts = 0; registry.retryAfter = nil
        try storage.update(JSONEncoder().encode(registry))
    }

    func recover(phrase: String, newPattern: [Int]) throws -> Vault {
        guard var registry = try read() else { throw VaultSettingsError.wrongPhrase }
        try checkCooldown(registry)
        guard PatternRules.isValid(newPattern, gridSize: registry.effectiveGridSize) else { throw PatternCredentialError.invalidPattern }
        var match: Int?
        for (index, entry) in registry.vaults.enumerated() {
            if let credential = entry.recovery, try RecoveryPhrase.matches(phrase, credential: credential) { match = index }
        }
        guard let index = match else { try recordFailure(&registry); throw VaultSettingsError.wrongPhrase }
        let vault = registry.vaults[index].vault
        if let other = try matchingVault(newPattern, in: registry), other.id != vault.id { throw PatternCredentialError.duplicatePattern }
        registry.vaults[index].pattern = try makeCredential(newPattern)
        registry.failedAttempts = 0; registry.retryAfter = nil
        try Task.checkCancellation()
        try storage.update(JSONEncoder().encode(registry))
        NotificationCenter.default.post(name: VaultEvents.accessRevoked, object: vault.id)
        return vault
    }

    func setDuressVault(vaultID: String, enabled: Bool, currentPattern: [Int]) throws {
        var registry = try authorizedRegistry(vaultID: vaultID, pattern: currentPattern)
        let index = registry.vaults.firstIndex { $0.vault.id == vaultID }!
        registry.vaults[index].isDuressVault = enabled
        try Task.checkCancellation()
        try storage.update(JSONEncoder().encode(registry))
    }

    func backupsAreDisabled() throws -> Bool { try read()?.backupsDisabled == true }

    func pendingRecoveryPhrase(vaultID: String, currentPattern: [Int]) throws -> String {
        let registry = try authorizedRegistry(vaultID: vaultID, pattern: currentPattern)
        guard let phrase = registry.vaults.first(where: { $0.vault.id == vaultID })?.pendingRecoveryPhrase else { throw VaultSettingsError.noRecovery }
        try storage.update(JSONEncoder().encode(registry))
        return phrase
    }

    func acknowledgeRecoveryPhrase(vaultID: String, phrase: String) throws {
        guard var registry = try read(), let index = registry.vaults.firstIndex(where: { $0.vault.id == vaultID }) else { throw VaultSettingsError.missingVault }
        guard registry.vaults[index].pendingRecoveryPhrase == phrase else { throw VaultSettingsError.wrongPhrase }
        registry.vaults[index].pendingRecoveryPhrase = nil
        try storage.update(JSONEncoder().encode(registry))
    }

    private func activateDuress(_ vault: Vault, registry: inout VaultRegistry) throws -> Vault {
        let trigger = registry.vaults.first { $0.vault.id == vault.id }!
        let displayID = trigger.dummyVaultID ?? vault.id
        guard var survivor = registry.vaults.first(where: { $0.vault.id == displayID }) else { throw VaultAccessError.invalidDummy }
        let revoked = Set(registry.vaults.filter { $0.vault.id != displayID }.map { $0.vault.id })
        let phrase = try RecoveryPhrase.generate()
        survivor.recovery = try RecoveryPhrase.credential(for: phrase)
        survivor.pendingRecoveryPhrase = phrase
        survivor.duressVaultID = nil
        survivor.dummyVaultID = nil
        registry.vaults = [survivor]
        registry.revokedVaultIDs = Set((registry.revokedVaultIDs ?? []) + Array(revoked)).sorted()
        registry.backupsDisabled = true
        registry.sharingEpoch = UUID()

        // Exclude the whole local vault tree before committing. If the Keychain
        // fails, credentials remain intact and backup exclusion fails closed.
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var root = directory
        try root.setResourceValues(values)
        for var child in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try child.setResourceValues(values) }
        }
        try Task.checkCancellation()
        // Credential removal, phrase rotation, cloud policy, and export
        // revocation have a single durable commit point.
        try storage.update(JSONEncoder().encode(registry))
        security.update(from: registry)
        faceIDChallenges.removeAll()
        NotificationCenter.default.post(name: VaultEvents.duressActivated, object: DuressActivation(revokedVaultIDs: revoked))
        return survivor.vault
    }

    /// The directory is staged before the credential is removed. If the app stops
    /// before the Keychain commit, LibraryRepository restores it on the next unlock.
    func deleteVault(vaultID: String, currentPattern: [Int], directory: URL) throws {
        var registry = try authorizedRegistry(vaultID: vaultID, pattern: currentPattern)
        try Task.checkCancellation()
        let root = directory.appending(path: vaultID)
        let staged = directory.appending(path: "DeletingVault-" + vaultID)
        let files = FileManager.default
        let exists = files.fileExists(atPath: root.path)
        if exists { try files.moveItem(at: root, to: staged) }
        registry.vaults.removeAll { $0.vault.id == vaultID }
        for index in registry.vaults.indices {
            if registry.vaults[index].duressVaultID == vaultID { registry.vaults[index].duressVaultID = nil }
            if registry.vaults[index].dummyVaultID == vaultID { registry.vaults[index].dummyVaultID = nil }
        }
        do { try storage.update(JSONEncoder().encode(registry)) }
        catch {
            if exists { try? files.moveItem(at: staged, to: root) }
            throw error
        }
        // A failed cleanup is retried at launch; removed credentials cannot expose it.
        try? files.removeItem(at: staged)
        NotificationCenter.default.post(name: VaultEvents.accessRevoked, object: vaultID)
    }

    func cleanDeletedVaults(in directory: URL) throws {
        let activeIDs = Set(try read()?.vaults.map { $0.vault.id } ?? [])
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { return }
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for prefix in ["DeletingVault-", "InstallingVault-"] where url.lastPathComponent.hasPrefix(prefix) {
                let id = String(url.lastPathComponent.dropFirst(prefix.count))
                if !activeIDs.contains(id) { try files.removeItem(at: url) }
            }
        }
    }

    /// Serialize the filesystem and Keychain transaction with launch cleanup.
    func installRestoredVault(_ vault: Vault, pattern: [Int], preparedDirectory: URL, directory: URL, lease: VaultSecurityState.Lease) throws {
        let current = try read()
        try security.check(lease)
        try purchaseAccess.checkAlbumCreation(currentCount: current?.vaults.count ?? 0)
        let restored = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: preparedDirectory.appending(path: "library.json")))
        try purchaseAccess.checkMediaAddition(currentCount: 0, adding: restored.items.count)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let staging = directory.appending(path: "InstallingVault-" + vault.id)
        do {
            try Task.checkCancellation()
            try files.copyItem(at: preparedDirectory, to: staging)
            try purchaseAccess.checkMediaAddition(currentCount: 0, adding: restored.items.count)
            try registerRestoredVault(vault, pattern: pattern)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
        // After the credential commits, the next unlock can finish this move.
        try? files.moveItem(at: staging, to: vault.root(in: directory))
    }

    /// Restore always creates a new vault. Existing libraries are never replaced.
    private func registerRestoredVault(_ vault: Vault, pattern: [Int]) throws {
        let previous = try read()
        var registry = previous ?? VaultRegistry()
        guard UUID(uuidString: vault.id) != nil, !(registry.revokedVaultIDs ?? []).contains(vault.id), !registry.vaults.contains(where: { $0.vault.id == vault.id }) else { throw PatternCredentialError.invalid }
        _ = try validatedName(vault.name, in: registry)
        guard PatternRules.isValid(pattern, gridSize: registry.effectiveGridSize) else { throw PatternCredentialError.invalidPattern }
        guard try matchingVault(pattern, in: registry) == nil else { throw PatternCredentialError.duplicatePattern }
        try purchaseAccess.checkAlbumCreation(currentCount: registry.vaults.count)
        registry.vaults.append(VaultCredential(vault: vault, pattern: try makeCredential(pattern)))
        let data = try JSONEncoder().encode(registry)
        try Task.checkCancellation()
        if previous == nil { try storage.create(data) } else { try storage.update(data) }
    }

    private func validatedName(_ name: String, in registry: VaultRegistry, excluding id: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40,
              !registry.vaults.contains(where: { $0.vault.id != id && $0.vault.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw VaultSettingsError.invalidName }
        return name
    }

    private func checkCooldown(_ registry: VaultRegistry) throws {
        if let until = registry.retryAfter, until > Date() { throw VaultSettingsError.cooldown(until) }
    }

    private func recordFailure(_ registry: inout VaultRegistry) throws {
        registry.failedAttempts = min(registry.failedAttempts + 1, 20)
        registry.retryAfter = registry.failedAttempts < 5 ? nil : Date().addingTimeInterval(min(300, 30 * pow(2, Double(registry.failedAttempts - 5))))
        try storage.update(JSONEncoder().encode(registry))
    }

    private func authorizedRegistry(vaultID: String, pattern: [Int]) throws -> VaultRegistry {
        guard var registry = try read(), let entry = registry.vaults.first(where: { $0.vault.id == vaultID }) else { throw VaultSettingsError.missingVault }
        try checkCooldown(registry)
        guard PatternRules.isValid(pattern, gridSize: registry.effectiveGridSize), constantTimeEqual(try derive(pattern, salt: entry.pattern.salt, rounds: entry.pattern.rounds), entry.pattern.verifier) else {
            try recordFailure(&registry)
            throw VaultSettingsError.wrongPattern
        }
        registry.failedAttempts = 0; registry.retryAfter = nil
        return registry
    }
}

nonisolated struct PatternGridConfiguration: Sendable {
    fileprivate let registry: VaultRegistry
    var gridSize: Int { registry.effectiveGridSize }
    var vaults: [Vault] { registry.vaults.map(\.vault).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
}

nonisolated struct VaultPatternReplacement: Sendable {
    let vaultID: String
    let current: [Int]
    let replacement: [Int]
    let confirmation: [Int]
}

nonisolated enum PatternConfigurationError: LocalizedError {
    case unsupportedSize, incomplete, mismatch, changed
    var errorDescription: String? {
        switch self {
        case .unsupportedSize: "Choose a 3 × 3, 4 × 4, or 5 × 5 grid."
        case .incomplete: "Confirm a new pattern for every vault before changing the grid."
        case .mismatch: "The new patterns didn’t match. Try again."
        case .changed: "Your vaults changed during setup. Start again to use the latest settings."
        }
    }
}

extension PatternAuthenticator {
    func registerFirstVault(name: String, pattern: [Int], gridSize: Int, recoveryPhrase: String) async throws -> Vault {
        guard PatternRules.supportedSizes.contains(gridSize) else { throw PatternConfigurationError.unsupportedSize }
        guard PatternRules.isValid(pattern, gridSize: gridSize) else { throw PatternCredentialError.invalidPattern }
        let previous = try read()
        guard previous?.vaults.isEmpty ?? true else { throw PatternCredentialError.alreadyRegistered }
        var registry = previous ?? VaultRegistry()
        let name = try validatedName(name, in: registry)
        let vault = Vault(id: previous == nil ? Vault.personal.id : UUID().uuidString, name: name)
        registry.gridSize = gridSize
        registry.vaults = [VaultCredential(vault: vault, pattern: try makeCredential(pattern), recovery: try RecoveryPhrase.credential(for: recoveryPhrase))]
        registry.failedAttempts = 0; registry.retryAfter = nil
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(registry)
        if previous == nil { try storage.create(data) } else { try storage.update(data) }
        return vault
    }

    func checkCanCreateVault() throws {
        try purchaseAccess.checkAlbumCreation(currentCount: try read()?.vaults.count ?? 0)
    }

    func gridConfiguration() throws -> PatternGridConfiguration {
        guard let registry = try read(), !registry.vaults.isEmpty else { throw PatternCredentialError.noPattern }
        return PatternGridConfiguration(registry: registry)
    }

    /// Authorizes without invoking the duress unlock route.
    func authorizeGridReplacement(vaultID: String, pattern: [Int]) throws {
        let registry = try authorizedRegistry(vaultID: vaultID, pattern: pattern)
        try storage.update(JSONEncoder().encode(registry))
    }

    func replaceAllPatterns(configuration: PatternGridConfiguration, gridSize: Int,
                            replacements: [VaultPatternReplacement], faceID: any FaceIDAuthenticating) async throws {
        guard PatternRules.supportedSizes.contains(gridSize), gridSize != configuration.gridSize else { throw PatternConfigurationError.unsupportedSize }
        guard let original = try read(), sameConfiguration(original, configuration.registry) else { throw PatternConfigurationError.changed }
        guard replacements.count == original.vaults.count,
              Set(replacements.map(\.vaultID)) == Set(original.vaults.map { $0.vault.id }) else { throw PatternConfigurationError.incomplete }
        var seen = Set<[Int]>()
        var updated = original
        for replacement in replacements {
            _ = try authorizedRegistry(vaultID: replacement.vaultID, pattern: replacement.current)
            guard replacement.replacement == replacement.confirmation else { throw PatternConfigurationError.mismatch }
            guard PatternRules.isValid(replacement.replacement, gridSize: gridSize) else { throw PatternCredentialError.invalidPattern }
            guard seen.insert(replacement.replacement).inserted else { throw PatternCredentialError.duplicatePattern }
            let index = updated.vaults.firstIndex { $0.vault.id == replacement.vaultID }!
            updated.vaults[index].pattern = try makeCredential(replacement.replacement)
        }
        if original.vaults.contains(where: { $0.requiresFaceID == true }) {
            guard await faceID.authenticate(reason: "Confirm Face ID to replace all vault patterns.") == .authenticated else { throw VaultAccessError.faceIDRequired }
        }
        try Task.checkCancellation()
        guard let latest = try read(), sameConfiguration(latest, original) else { throw PatternConfigurationError.changed }
        try checkCooldown(latest)
        updated.gridSize = gridSize
        updated.failedAttempts = 0; updated.retryAfter = nil
        // One Keychain update changes every verifier and the grid together.
        try storage.update(JSONEncoder().encode(updated))
        faceIDChallenges.removeAll()
        NotificationCenter.default.post(name: VaultEvents.gridChanged, object: nil)
    }

    private func sameConfiguration(_ lhs: VaultRegistry, _ rhs: VaultRegistry) -> Bool {
        var lhs = lhs, rhs = rhs
        lhs.failedAttempts = 0; lhs.retryAfter = nil
        rhs.failedAttempts = 0; rhs.retryAfter = nil
        return lhs == rhs
    }
}
