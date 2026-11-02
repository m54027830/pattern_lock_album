import Foundation
import Observation

nonisolated enum PatternLockStage: Equatable {
    case loading, nameVault, create, confirm, locked, unlocked, unavailable
}

@MainActor @Observable final class PatternLockStore {
    private(set) var stage = PatternLockStage.loading
    private(set) var unlockedVault: Vault?
    private(set) var isCreatingVault = false
    var vaultName = ""
    private(set) var isBusy = false
    private(set) var isActive = false
    private(set) var message: String?
    private(set) var retryAfter: Date?
    private(set) var inputRevision = 0
    private(set) var failureRevision = 0
    private var pendingPattern: [Int]?
    private var returnVault: Vault?
    private var generation = 0
    private let authenticator: any PatternAuthenticating

    init(authenticator: any PatternAuthenticating = PatternAuthenticator.shared) { self.authenticator = authenticator }

    func activate() async {
        isActive = true
        guard (stage == .loading || stage == .unavailable), !isBusy else { return }
        let operation = generation
        isBusy = true
        defer { if operation == generation { isBusy = false } }
        do {
            let status = try await authenticator.status()
            guard operation == generation, isActive else { return }
            stage = status.isRegistered ? .locked : .create
            retryAfter = status.retryAfter
            message = nil
        } catch {
            guard operation == generation, isActive else { return }
            stage = .unavailable
            message = error.localizedDescription
        }
    }

    func becameInactive() {
        guard isActive else { return }
        isActive = false
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
        guard unlockedVault?.id == vaultID || returnVault?.id == vaultID else { return false }
        lock()
        return true
    }

    func beginNewVault() {
        guard stage == .unlocked, isActive, !isBusy, let unlockedVault else { return }
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
        guard PatternRules.isValid(nodes) else { reject("Connect at least 4 different dots."); return }
        message = nil
        switch stage {
        case .create:
            pendingPattern = nodes
            stage = .confirm
            inputRevision += 1
        case .confirm:
            guard nodes == pendingPattern else { reject("Those patterns didn’t match. Try again."); return }
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
                guard authenticator.accessIsAllowed(to: vault.id) else { throw VaultSettingsError.missingVault }
                resetSession()
                unlockedVault = vault
                retryAfter = nil
                stage = .unlocked
                inputRevision += 1
            case .rejected(let retryAfter):
                self.retryAfter = retryAfter
                reject(retryAfter == nil ? "That pattern wasn’t right. Try again." : "Too many attempts. Take a moment and try again.")
            }
        } catch let error as PatternCredentialError where registering && isCreatingVault && (error == .duplicatePattern || error == .duplicateVaultName || error == .invalidVaultName) {
            guard operation == generation, isActive else { return }
            pendingPattern = nil
            stage = error == .duplicatePattern ? .create : .nameVault
            reject(error.localizedDescription)
        } catch {
            guard operation == generation, isActive else { return }
            resetSession()
            stage = .unavailable
            message = error.localizedDescription
            inputRevision += 1
        }
    }

    private func resetSession() {
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
