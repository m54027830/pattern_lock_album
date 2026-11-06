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
    var useCustomPhrase = false
    var customPhrase = ""
    var confirmation = ""
    var savedPhrase = false
    private(set) var error: String?
    private(set) var revision = 0
    private(set) var busy = false

    // Avoid Swift 6.2's synthesized isolated-deinit crash on iOS 26.2.
    // This store has no cleanup that needs to run on the main actor.
    // https://github.com/swiftlang/swift/issues/88036
    deinit {}

    var phrase: String { useCustomPhrase ? RecoveryPhrase.normalized(customPhrase) : generatedPhrase }
    var canFinish: Bool { savedPhrase && !phrase.isEmpty && RecoveryPhrase.normalized(confirmation) == phrase }

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
            step = .recovery
        } catch { self.error = error.localizedDescription }
    }
    func confirmRecovery() {
        do {
            try RecoveryPhrase.validate(phrase)
            confirmation = ""; savedPhrase = false; error = nil; step = .verifyRecovery
        } catch { self.error = error.localizedDescription }
    }
    func back() {
        guard !busy else { return }
        error = nil; revision += 1
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
    func finish(_ save: @MainActor (String, [Int], Int, String) async throws -> Void) async {
        guard step == .verifyRecovery, canFinish, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await save(vaultName.trimmingCharacters(in: .whitespacesAndNewlines), pattern, gridSize, phrase)
            clearSecrets()
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func clearSecrets() { pattern = []; clearRecovery() }
    private func clearRecovery() { generatedPhrase = ""; customPhrase = ""; confirmation = ""; savedPhrase = false }
}
