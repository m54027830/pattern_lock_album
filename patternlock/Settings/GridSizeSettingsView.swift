import SwiftUI
import Observation

nonisolated enum GridChangeStep { case choose, current, new, confirm, review }

@MainActor @Observable final class GridChangeStore {
    private(set) var configuration: PatternGridConfiguration?
    private(set) var step = GridChangeStep.choose
    var gridSize = 5
    private(set) var index = 0
    private(set) var replacements: [VaultPatternReplacement] = []
    private var current: [Int] = []
    private var proposed: [Int] = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var revision = 0
    let authenticator: PatternAuthenticator
    var vault: Vault? { configuration.flatMap { index < $0.vaults.count ? $0.vaults[index] : nil } }
    var drawingSize: Int { step == .current ? configuration?.gridSize ?? 5 : gridSize }

    init(authenticator: PatternAuthenticator) { self.authenticator = authenticator }
    func load() async {
        do {
            let value = try await authenticator.gridConfiguration()
            guard !Task.isCancelled else { return }
            clearSecrets(); configuration = value; gridSize = value.gridSize; step = .choose; index = 0; error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func begin() {
        guard let configuration, configuration.gridSize != gridSize, PatternRules.supportedSizes.contains(gridSize), !busy else { return }
        clearSecrets(); index = 0; step = .current; error = nil; revision += 1
    }
    func submit(_ pattern: [Int]) async {
        guard !busy, let vault, [.current, .new, .confirm].contains(step) else { return }
        revision += 1; error = nil
        guard PatternRules.isValid(pattern, gridSize: drawingSize) else { error = "Connect at least 4 different dots."; return }
        switch step {
        case .current:
            busy = true
            defer { busy = false }
            do {
                try await authenticator.authorizeGridReplacement(vaultID: vault.id, pattern: pattern)
                guard !Task.isCancelled else { return }
                current = pattern; step = .new
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        case .new:
            guard !replacements.contains(where: { $0.replacement == pattern }) else { error = PatternCredentialError.duplicatePattern.localizedDescription; return }
            proposed = pattern; step = .confirm
        case .confirm:
            guard proposed == pattern else { error = PatternConfigurationError.mismatch.localizedDescription; return }
            replacements.append(VaultPatternReplacement(vaultID: vault.id, current: current, replacement: proposed, confirmation: pattern))
            current = []; proposed = []
            index += 1
            step = index == configuration?.vaults.count ? .review : .current
        default: break
        }
    }
    func back() {
        guard !busy else { return }
        error = nil; revision += 1
        switch step {
        case .choose: break
        case .confirm: proposed = []; step = .new
        case .new: current = []; proposed = []; step = .current
        case .current, .review:
            current = []; proposed = []
            if index > 0 { index -= 1; replacements.removeLast(); step = .current }
            else { step = .choose }
        }
    }
    func save(faceID: any FaceIDAuthenticating) async -> Bool {
        guard !busy, step == .review, let configuration else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await authenticator.replaceAllPatterns(configuration: configuration, gridSize: gridSize, replacements: replacements, faceID: faceID)
            clearSecrets(); return true
        } catch { if !Task.isCancelled { self.error = error.localizedDescription }; return false }
    }
    func clearSecrets() { current = []; proposed = []; replacements = [] }
}

struct GridSizeSettingsView: View {
    @State private var change: GridChangeStore
    @State private var drawing = false
    @State private var operation: Task<Void, Never>?
    @State private var faceID = FaceIDAuthenticator()
    @Environment(\.dismiss) private var dismiss

    init(authenticator: PatternAuthenticator) { _change = State(initialValue: GridChangeStore(authenticator: authenticator)) }

    private var instruction: String {
        switch change.step {
        case .current: "Confirm the current pattern"
        case .new: "Draw a new pattern"
        case .confirm: "Repeat the new pattern"
        default: "Pattern grid"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    if let configuration = change.configuration {
                        if change.step == .choose {
                            Image(systemName: "circle.grid.3x3").font(.system(size: 36, weight: .light)).foregroundStyle(AlbumTheme.accent)
                            Text("One grid for every vault.").font(.title2.weight(.semibold))
                            Text("Current grid: \(configuration.gridSize) × \(configuration.gridSize)").font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                            GridSizePicker(selection: $change.gridSize)
                            Text("Changing the grid requires a new pattern for all \(configuration.vaults.count) vaults. You’ll confirm each current pattern, then draw its replacement twice. You’ll need Face ID too if any vault uses it.")
                            Text("Your photos, folders, recovery phrases, and Face ID settings stay in place. Nothing changes until every pattern is ready and you save.")
                                .font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                            Button("Reset all vault patterns", action: change.begin).buttonStyle(.borderedProminent)
                                .disabled(change.gridSize == configuration.gridSize).accessibilityIdentifier("beginGridChange")
                        } else if change.step == .review {
                            Image(systemName: "checkmark.shield").font(.system(size: 42, weight: .light)).foregroundStyle(AlbumTheme.accent)
                            Text("All patterns are ready.").font(.title2.weight(.semibold))
                            Text("Switch to \(change.gridSize) × \(change.gridSize) and replace the patterns for these vaults:")
                            ForEach(configuration.vaults) { vault in Label(vault.name, systemImage: "checkmark.circle").frame(maxWidth: .infinity, alignment: .leading) }
                            Text("You’ll return to the lock screen. Use the new patterns from now on.").font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                            Button("Save grid and all patterns") {
                                operation = Task { if await change.save(faceID: faceID) { dismiss() } }
                            }.buttonStyle(.borderedProminent).accessibilityIdentifier("saveGridChange")
                        } else if let vault = change.vault {
                            Text("Vault \(change.index + 1) of \(configuration.vaults.count)").font(.caption).foregroundStyle(AlbumTheme.secondary)
                            Text(vault.name).font(.title2.weight(.semibold))
                            Text(instruction).font(.headline)
                            Text("\(change.drawingSize) × \(change.drawingSize) grid · at least 4 dots").font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                            PatternGridView(side: min(300, geometry.size.width - 48), gridSize: change.drawingSize, isEnabled: !change.busy, revision: change.revision, isDrawing: $drawing) { pattern in
                                operation = Task { await change.submit(pattern) }
                            }
                            Text("Confirming a current pattern here does not activate duress.").font(.caption).foregroundStyle(AlbumTheme.secondary)
                        }
                        if change.step != .choose { Button("Back", action: change.back) }
                    } else { ProgressView() }
                    if change.busy { ProgressView("Confirming…") }
                    if let error = change.error {
                        Text(error).foregroundStyle(.red)
                        Button("Start again") { operation = Task { await change.load() } }
                    }
                }.multilineTextAlignment(.center).padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .scrollDisabled(drawing).disabled(change.busy)
        }
        .background(AlbumTheme.background).tint(AlbumTheme.accent)
        .navigationTitle("Pattern grid").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(change.step != .choose)
        .toolbar { if change.step != .choose { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(change.busy) } } }
        .task { await change.load() }
        .onDisappear { operation?.cancel(); faceID.cancel(); change.clearSecrets() }
    }
}
