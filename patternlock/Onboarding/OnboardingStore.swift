import Foundation
import Observation

nonisolated enum OnboardingStep: Int, CaseIterable { case welcome, vaultChoice, grid, pattern, confirm, recovery, verifyRecovery }

@MainActor @Observable final class OnboardingStore {
    private(set) var step = OnboardingStep.welcome
    var welcomePage = 0
    var gridSize = 5
    var vaultName = String(localized: "Personal")
    private(set) var pattern: [Int] = []
    private(set) var generatedPhrase = ""
    var useCustomPhrase = false {
        didSet { if oldValue != useCustomPhrase { resetPhraseSaving() } }
    }
    var customPhrase = "" {
        didSet { if oldValue != customPhrase { resetPhraseSaving() } }
    }
    var confirmation = ""
    var savedPhrase = false
    private(set) var copiedPhrase = false
    private(set) var sharedPhrase = false
    private(set) var phraseID = UUID()
    private(set) var recoveryConfirmationMismatch = false
    private(set) var error: String?
    private(set) var revision = 0
    private(set) var busy = false

    // Avoid Swift 6.2's synthesized isolated-deinit crash on iOS 26.2.
    // This store has no cleanup that needs to run on the main actor.
    // https://github.com/swiftlang/swift/issues/88036
    deinit {}

    var phrase: String { useCustomPhrase ? RecoveryPhrase.normalized(customPhrase) : generatedPhrase }
    var canSavePhrase: Bool { (try? RecoveryPhrase.validate(phrase)) != nil }
    var canContinueRecovery: Bool { canSavePhrase && (copiedPhrase || sharedPhrase) }
    var canFinish: Bool { canContinueRecovery && savedPhrase && RecoveryPhrase.normalized(confirmation) == phrase }

    func showVaultChoices() { step = .vaultChoice; error = nil }
    func startSetup() { step = .grid; error = nil }
    func chooseGrid() {
        guard PatternRules.supportedSizes.contains(gridSize) else { return }
        step = .pattern; error = nil
    }
    func submit(_ nodes: [Int]) {
        guard !busy, step == .pattern || step == .confirm else { return }
        revision += 1; error = nil
        guard PatternRules.isValid(nodes, gridSize: gridSize) else { error = String(localized: "Connect at least 4 different dots."); return }
        let name = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { error = String(localized: "Give your first vault a name between 1 and 40 characters."); return }
        if step == .pattern { pattern = nodes; step = .confirm; return }
        guard nodes == pattern else { error = String(localized: "Those patterns didn’t match. Try again."); return }
        do {
            generatedPhrase = try RecoveryPhrase.generate()
            resetPhraseSaving()
            step = .recovery
        } catch { self.error = error.localizedDescription }
    }
    func confirmRecovery() {
        guard step == .recovery, !busy else { return }
        do {
            try RecoveryPhrase.validate(phrase)
            guard canContinueRecovery else {
                error = String(localized: "Copy or share your phrase before continuing.")
                return
            }
            confirmation = ""; savedPhrase = false; recoveryConfirmationMismatch = false; error = nil; step = .verifyRecovery
        } catch { self.error = error.localizedDescription }
    }
    func markPhraseCopied() {
        guard step == .recovery, canSavePhrase, !busy else { return }
        copiedPhrase = true; error = nil
    }
    func recordPhraseShare(completed: Bool, phraseID: UUID) {
        // A dismissed share sheet or a completion for an earlier phrase cannot
        // unlock the next step for the current phrase.
        guard completed, phraseID == self.phraseID, step == .recovery, canSavePhrase, !busy else { return }
        sharedPhrase = true; error = nil
    }
    func back() {
        guard !busy else { return }
        error = nil; recoveryConfirmationMismatch = false; revision += 1
        switch step {
        case .welcome: welcomePage = max(0, welcomePage - 1)
        case .vaultChoice: step = .welcome
        case .grid: step = .vaultChoice
        case .pattern: pattern = []; step = .grid
        case .confirm: pattern = []; step = .pattern
        case .recovery: clearRecovery(); pattern = []; step = .pattern
        case .verifyRecovery: confirmation = ""; savedPhrase = false; step = .recovery
        }
    }
    @discardableResult
    func confirmRecoveryPhrase() -> Bool {
        guard step == .verifyRecovery, !busy else { return false }
        error = nil; recoveryConfirmationMismatch = false
        guard canContinueRecovery else {
            step = .recovery
            error = String(localized: "Copy or share your phrase before continuing.")
            return false
        }
        guard RecoveryPhrase.normalized(confirmation) == phrase else {
            recoveryConfirmationMismatch = true
            error = String(localized: "That phrase doesn’t match. Go back to view and save your phrase, then return here to paste or type every word in order.")
            return false
        }
        guard savedPhrase else {
            error = String(localized: "Confirm that you saved your phrase outside PatternVault before continuing.")
            return false
        }
        return true
    }

    func finish(_ save: @MainActor (String, [Int], Int, String) async throws -> Void) async {
        guard confirmRecoveryPhrase() else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await save(vaultName.trimmingCharacters(in: .whitespacesAndNewlines), pattern, gridSize, phrase)
            clearSecrets()
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func clearSecrets() { pattern = []; clearRecovery() }
    private func resetPhraseSaving() {
        phraseID = UUID()
        copiedPhrase = false; sharedPhrase = false
        confirmation = ""; savedPhrase = false; recoveryConfirmationMismatch = false; error = nil
    }
    private func clearRecovery() {
        generatedPhrase = ""; customPhrase = ""; useCustomPhrase = false
        resetPhraseSaving()
    }
}
