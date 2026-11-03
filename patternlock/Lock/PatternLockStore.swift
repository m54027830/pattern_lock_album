import Foundation
import Observation

nonisolated enum PatternLockStage: Equatable {
    case loading, onboarding, nameVault, create, confirm, locked, faceID, unlocked, unavailable
}

@MainActor @Observable final class PatternLockStore {
    private(set) var stage = PatternLockStage.loading
    private(set) var gridSize = 5
    private(set) var unlockedVault: Vault?
    private(set) var isDummySession = false
    private(set) var isCreatingVault = false
    var vaultName = ""
    private(set) var isBusy = false
    private(set) var isActive = false
    var purchaseLimit: FreeTierLimit?
    private(set) var message: String?
    private(set) var retryAfter: Date?
    private(set) var inputRevision = 0
    private(set) var failureRevision = 0
    private var pendingPattern: [Int]?
    private var returnVault: Vault?
    private var generation = 0
    private let authenticator: any PatternAuthenticating
    private let faceID: any FaceIDAuthenticating
    private var faceIDChallenge: FaceIDChallenge?
    private var activeWaiter: CheckedContinuation<Bool, Never>?

    init(authenticator: any PatternAuthenticating = PatternAuthenticator.shared, faceID: (any FaceIDAuthenticating)? = nil) {
        self.authenticator = authenticator
        self.faceID = faceID ?? FaceIDAuthenticator()
    }

    func activate() async {
        isActive = true
        activeWaiter?.resume(returning: true)
        activeWaiter = nil
        guard (stage == .loading || stage == .unavailable), !isBusy else { return }
        let operation = generation
        isBusy = true
        defer { if operation == generation { isBusy = false } }
        do {
            let status = try await authenticator.status()
            guard operation == generation, isActive else { return }
            gridSize = status.gridSize
            stage = status.isRegistered ? .locked : .onboarding
            retryAfter = status.retryAfter
            message = nil
        } catch {
            guard operation == generation, isActive else { return }
            stage = .unavailable
            message = error.localizedDescription
        }
    }

    func finishOnboarding(name: String, pattern: [Int], gridSize: Int, recoveryPhrase: String) async throws {
        guard stage == .onboarding, isActive, !isBusy else { throw CancellationError() }
        let operation = generation
        isBusy = true
        defer { if operation == generation { isBusy = false } }
        let vault = try await authenticator.registerFirstVault(name: name, pattern: pattern, gridSize: gridSize, recoveryPhrase: recoveryPhrase)
        guard operation == generation, isActive, !Task.isCancelled else { throw CancellationError() }
        self.gridSize = gridSize
        try open(vault, dummy: false)
    }

    func becameInactive() {
        guard isActive else { return }
        isActive = false
        // Face ID's own system prompt can temporarily deactivate the scene.
        // Only backgrounding cancels this request and invalidates its result.
        if stage == .faceID && faceIDChallenge != nil { inputRevision += 1; return }
        generation += 1
        inputRevision += 1
        if isBusy { resetSession(); stage = .loading }
        isBusy = false
    }

    func enteredBackground() {
        becameInactive()
        lock()
    }

    /// Also used to switch vaults: the next pattern chooses the destination.
    func lock() {
        generation += 1
        resetSession()
        stage = .loading
        message = nil
        isBusy = false
        inputRevision += 1
    }

    func updateUnlockedVault(_ vault: Vault) {
        guard stage == .unlocked, unlockedVault?.id == vault.id else { return }
        unlockedVault = vault
    }

    @discardableResult
    func revokeAccess(to vaultID: String) -> Bool {
        guard unlockedVault?.id == vaultID || returnVault?.id == vaultID || faceIDChallenge?.vaultID == vaultID else { return false }
        lock()
        return true
    }

    func beginNewVault() {
        guard stage == .unlocked, !isDummySession, isActive, !isBusy, let unlockedVault else { return }
        returnVault = unlockedVault
        self.unlockedVault = nil
        isCreatingVault = true
        vaultName = ""
        message = nil
        stage = .nameVault
        inputRevision += 1
    }

    func continueWithVaultName() {
        guard stage == .nameVault, isCreatingVault else { return }
        let name = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { reject(PatternCredentialError.invalidVaultName.localizedDescription); return }
        vaultName = name
        message = nil
        stage = .create
        inputRevision += 1
    }

    func editVaultName() {
        guard isCreatingVault, !isBusy else { return }
        pendingPattern = nil
        message = nil
        stage = .nameVault
        inputRevision += 1
    }

    func cancelNewVault() {
        guard isCreatingVault, !isBusy, isActive, let returnVault else { return }
        guard authenticator.accessIsAllowed(to: returnVault.id) else { lock(); return }
        resetSession()
        unlockedVault = returnVault
        stage = .unlocked
        message = nil
        inputRevision += 1
    }

    func startOver() {
        guard stage == .confirm, !isBusy else { return }
        pendingPattern = nil
        stage = .create
        message = nil
        inputRevision += 1
    }

    func submit(_ nodes: [Int], now: Date = Date()) async {
        guard isActive, !isBusy, [.create, .confirm, .locked].contains(stage) else { return }
        if let retryAfter, retryAfter > now { return }
        guard PatternRules.isValid(nodes, gridSize: gridSize) else { reject(String(localized: "Connect at least 4 different dots.")); return }
        message = nil
        switch stage {
        case .create:
            pendingPattern = nodes
            stage = .confirm
            inputRevision += 1
        case .confirm:
            guard nodes == pendingPattern else { reject(String(localized: "Those patterns didn’t match. Try again.")); return }
            await authenticate(nodes, registering: true, now: now)
        case .locked:
            await authenticate(nodes, registering: false, now: now)
        default: break
        }
    }

    private func authenticate(_ nodes: [Int], registering: Bool, now: Date) async {
        let operation = generation
        isBusy = true
        defer { if operation == generation { isBusy = false } }
        do {
            let result: PatternVerification
            if registering {
                let vault = isCreatingVault
                    ? try await authenticator.createVault(name: vaultName, pattern: nodes, from: returnVault!.id)
                    : try await authenticator.register(nodes)
                result = .accepted(vault)
            } else {
                result = try await authenticator.verify(nodes, now: now)
            }
            guard operation == generation, isActive else { return }
            switch result {
            case .accepted(let vault):
                try open(vault, dummy: false)
            case .dummy(let vault):
                try open(vault, dummy: true)
            case .requiresFaceID(let challenge):
                faceIDChallenge = challenge
                stage = .faceID
                inputRevision += 1
                let result = await faceID.authenticate(reason: String(localized: "Unlock your vault after entering its pattern."))
                guard operation == generation else { return }
                guard result != .interrupted else {
                    await authenticator.cancelFaceID(challenge)
                    guard operation == generation else { return }
                    resetSession(); stage = .locked
                    message = VaultAccessError.interrupted.localizedDescription
                    return
                }
                guard await waitUntilActive(operation: operation) else { return }
                let resolved = try await authenticator.completeFaceID(challenge, result: result)
                guard await waitUntilActive(operation: operation) else { return }
                switch resolved {
                case .accepted(let vault): try open(vault, dummy: false)
                case .dummy(let vault): try open(vault, dummy: true)
                default: throw VaultAccessError.changed
                }
            case .rejected(let retryAfter):
                self.retryAfter = retryAfter
                reject(retryAfter == nil ? String(localized: "That pattern wasn’t right. Try again.") : String(localized: "Too many attempts. Take a moment and try again."))
            }
        } catch let error as PatternCredentialError where registering && isCreatingVault && (error == .duplicatePattern || error == .duplicateVaultName || error == .invalidVaultName) {
            guard operation == generation, isActive else { return }
            pendingPattern = nil
            stage = error == .duplicatePattern ? .create : .nameVault
            reject(error.localizedDescription)
        } catch let limit as FreeTierLimit {
            guard operation == generation, isActive else { return }
            pendingPattern = nil
            stage = .create
            purchaseLimit = limit
            reject(limit.localizedDescription)
        } catch is VaultAccessError {
            guard operation == generation else { return }
            resetSession()
            stage = .locked
            message = String(localized: "Couldn’t open the vault. Enter your pattern to try again.")
            inputRevision += 1
        } catch {
            guard operation == generation, isActive || stage == .faceID else { return }
            resetSession()
            stage = .unavailable
            message = error.localizedDescription
            inputRevision += 1
        }
    }

    private func waitUntilActive(operation: Int) async -> Bool {
        guard operation == generation else { return false }
        if isActive { return true }
        let resumed = await withCheckedContinuation { activeWaiter = $0 }
        return resumed && operation == generation && isActive
    }

    private func open(_ vault: Vault, dummy: Bool) throws {
        guard authenticator.accessIsAllowed(to: vault.id) else { throw VaultSettingsError.missingVault }
        resetSession()
        unlockedVault = vault
        isDummySession = dummy
        retryAfter = nil
        stage = .unlocked
        inputRevision += 1
    }

    private func resetSession() {
        purchaseLimit = nil
        faceID.cancel()
        activeWaiter?.resume(returning: false)
        activeWaiter = nil
        if let challenge = faceIDChallenge { Task { await authenticator.cancelFaceID(challenge) } }
        faceIDChallenge = nil
        isDummySession = false
        pendingPattern = nil
        unlockedVault = nil
        returnVault = nil
        isCreatingVault = false
        vaultName = ""
    }

    private func reject(_ message: String) {
        self.message = message
        failureRevision += 1
        inputRevision += 1
    }
}
