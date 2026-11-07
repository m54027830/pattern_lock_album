import SwiftUI

struct PatternSetupView: View {
    let title: String
    let needsCurrentPattern: Bool
    let completion: ([Int], [Int]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var purchaseLimit: FreeTierLimit?
    @State private var current: [Int] = []
    @State private var proposed: [Int] = []
    @State private var revision = 0
    @Environment(\.patternGridSize) private var gridSize
    @State private var isDrawing = false
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    private var needsCurrent: Bool { needsCurrentPattern && current.isEmpty }
    private var instruction: String {
        if needsCurrent { return String(localized: "Draw this vault’s current pattern.") }
        return proposed.isEmpty ? String(localized: "Draw a new pattern with at least 4 dots.") : String(localized: "Draw the new pattern again to confirm.")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "hand.draw").font(.system(size: 36, weight: .light)).foregroundStyle(AlbumTheme.accent)
                Text(instruction).font(.title3.weight(.medium)).multilineTextAlignment(.center)
                PatternGridView(side: 300, isEnabled: !busy, revision: revision, isDrawing: $isDrawing, completed: submit)
                if busy { ProgressView(String(localized: "Saving pattern…")) }
                if let error { Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center) }
                if !proposed.isEmpty && !busy {
                    Button(String(localized: "Start over")) { current = []; proposed = []; error = nil; revision += 1 }
                }
            }.padding(24).frame(maxWidth: .infinity)
        }
        .scrollDisabled(isDrawing)
        .background(AlbumTheme.background)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy)
        .sheet(item: $purchaseLimit) { PurchaseView(reason: $0) }
        .onDisappear { operation?.cancel(); current = []; proposed = [] }
    }

    private func submit(_ pattern: [Int]) {
        guard !busy else { return }
        revision += 1
        guard PatternRules.isValid(pattern, gridSize: gridSize) else { error = String(localized: "Connect at least 4 different dots."); return }
        error = nil
        if needsCurrent { current = pattern; return }
        if proposed.isEmpty { proposed = pattern; return }
        guard proposed == pattern else { error = String(localized: "Those patterns didn’t match. Try again."); return }
        busy = true
        operation = Task {
            do {
                try await completion(current, pattern)
                if !Task.isCancelled { dismiss() }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription; current = []; proposed = []
                    if let limit = error as? FreeTierLimit { purchaseLimit = limit }
                }
            }
            busy = false
        }
    }
}

struct PatternAuthorizationView: View {
    let title: String
    let detail: String
    let completion: ([Int]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    @Environment(\.patternGridSize) private var gridSize
    @State private var isDrawing = false
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(detail).font(.subheadline).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
                Text(String(localized: "Confirm your current pattern")).font(.headline)
                PatternGridView(side: 300, isEnabled: !busy, revision: revision, isDrawing: $isDrawing) { pattern in
                    guard !busy else { return }
                    revision += 1
                    guard PatternRules.isValid(pattern, gridSize: gridSize) else { error = String(localized: "Connect at least 4 different dots."); return }
                    busy = true; error = nil
                    operation = Task {
                        do { try await completion(pattern); if !Task.isCancelled { dismiss() } }
                        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        busy = false
                    }
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center) }
            }.padding(24).frame(maxWidth: .infinity)
        }
        .scrollDisabled(isDrawing)
        .background(AlbumTheme.background)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy)
        .onDisappear { operation?.cancel() }
    }
}

struct RecoveryPhraseSettingsView: View {
    let vault: Vault
    let generated: Bool
    let authenticator: PatternAuthenticator
    let completion: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var confirmation = ""
    @State private var savedPhrase = false
    @State private var error: String?

    private var valid: Bool { (try? RecoveryPhrase.validate(phrase)) != nil }

    var body: some View {
        Form {
            Section {
                if generated {
                    Text(phrase).font(.system(.body, design: .monospaced)).textSelection(.enabled).privacySensitive()
                } else {
                    SecureField(String(localized: "At least 8 words and 40 characters"), text: $phrase)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                }
            } header: { Text(generated ? String(localized: "New recovery phrase") : String(localized: "Custom recovery phrase")) } footer: {
                Text(String(localized: "Keep this phrase somewhere safe outside Pattern. Anyone with it can reset this vault’s pattern and open backups made with it. Custom phrases are only as strong as the words you choose."))
            }
            Section {
                SecureField(String(localized: "Repeat the whole phrase"), text: $confirmation)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Toggle(String(localized: "I saved it somewhere safe"), isOn: $savedPhrase)
            } footer: {
                Text(String(localized: "The old phrase stops working for local recovery immediately. Your cloud backup uses the new phrase after the next successful backup. Exported files always need their original phrases."))
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                NavigationLink(String(localized: "Confirm and save phrase")) {
                    PatternAuthorizationView(title: String(localized: "Save recovery phrase"), detail: String(localized: "This replaces this vault’s previous recovery phrase.")) { pattern in
                        try await authenticator.setRecoveryPhrase(vaultID: vault.id, phrase: phrase, currentPattern: pattern)
                        completion(); dismiss()
                    }
                }
                .disabled(!valid || !savedPhrase || RecoveryPhrase.normalized(confirmation) != RecoveryPhrase.normalized(phrase))
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(generated ? String(localized: "Generate recovery phrase") : String(localized: "Custom recovery phrase")).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if generated && phrase.isEmpty {
                do { phrase = try RecoveryPhrase.generate() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct PendingRecoveryPhraseView: View {
    let vault: Vault
    let authenticator: PatternAuthenticator
    let completion: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var confirmation = ""
    @State private var saved = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            if phrase.isEmpty {
                Section {
                    NavigationLink(String(localized: "Show new recovery phrase")) {
                        PatternAuthorizationView(title: String(localized: "Recovery phrase"), detail: String(localized: "Confirm your pattern to see the phrase created during the latest duress unlock. This confirmation doesn’t activate duress.")) { pattern in
                            let value = try await authenticator.pendingRecoveryPhrase(vaultID: vault.id, currentPattern: pattern)
                            try Task.checkCancellation()
                            phrase = value
                        }
                    }
                }
            } else {
                Section {
                    Text(phrase).font(.system(.body, design: .monospaced)).textSelection(.enabled).privacySensitive()
                } footer: { Text(String(localized: "Save this phrase outside Pattern. Your previous phrase no longer recovers this vault. Existing backup files still use their original phrases.")) }
                Section {
                    SecureField(String(localized: "Repeat the whole phrase"), text: $confirmation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Toggle(String(localized: "I saved it somewhere safe"), isOn: $saved)
                    Button(String(localized: "Done")) {
                        busy = true
                        Task {
                            do {
                                try await authenticator.acknowledgeRecoveryPhrase(vaultID: vault.id, phrase: phrase)
                                phrase = ""; confirmation = ""; completion(); dismiss()
                            } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.disabled(!saved || RecoveryPhrase.normalized(confirmation) != phrase || busy)
                } footer: { Text(String(localized: "Once saved, this phrase will no longer be displayed. Every duress unlock creates a new one.")) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "New recovery phrase")).navigationBarTitleDisplayMode(.inline)
        .onDisappear { phrase = ""; confirmation = "" }
    }
}
