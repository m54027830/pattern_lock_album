import SwiftUI

struct FaceIDSettingsView: View {
    let vault: Vault
    let authenticator: PatternAuthenticator
    let completion: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var requireFaceID = false
    @State private var dummyVaultID: String?
    @State private var originalDummyID: String?
    @State private var available: [Vault] = []
    @State private var isDuressVault = false
    @State private var loaded = false
    @State private var error: String?

    private var dummy: Vault? { available.first { $0.id == dummyVaultID } }

    var body: some View {
        Form {
            Section {
                Toggle("Require Face ID after pattern", isOn: $requireFaceID)
                    .accessibilityIdentifier("requireFaceID")
            } header: { Text("Face ID") } footer: {
                Text("Your pattern selects a vault. When enabled, Face ID must succeed before its photos and folders appear. The device passcode cannot replace this check.")
            }
            Section {
                Picker("Dummy vault", selection: $dummyVaultID) {
                    Text("Not set").tag(nil as String?)
                    ForEach(available) { vault in Text(vault.name).tag(Optional(vault.id)) }
                }.accessibilityIdentifier("dummyVaultPicker")
                if available.isEmpty {
                    Text("Create another vault from the library’s vault menu, then choose it here.")
                        .font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                }
            } header: { Text("What to show instead") } footer: {
                Text("If Face ID fails, is cancelled, or is unavailable, this vault is shown. That does not activate duress, remove access, rotate recovery phrases, or stop backups. A dummy session can browse its media but cannot change vault settings or create vaults. Unlock its own pattern for full access.")
            }
            Section {
                Text(isDuressVault
                     ? "Duress is enabled for this pattern. A duress unlock keeps the selected dummy vault (or this vault if none is selected) and removes access to all other vaults on this device, including this one when a different dummy is selected. Face ID failure never performs those actions."
                     : "The same dummy vault is displayed if you separately enable and use duress. Choosing a dummy here does not enable duress.")
                    .font(.subheadline)
            } header: { Text("Duress") }
            Section {
                NavigationLink {
                    FaceIDSettingsConfirmationView(vault: vault, requireFaceID: requireFaceID, dummy: dummy,
                                                   needsDummyPattern: dummyVaultID != nil && dummyVaultID != originalDummyID,
                                                   authenticator: authenticator) {
                        completion(); dismiss()
                    }
                } label: { Text("Confirm and save").fontWeight(.semibold) }
                .disabled(requireFaceID && dummy == nil)
                .accessibilityIdentifier("saveFaceIDSettings")
            } footer: {
                Text(requireFaceID && dummy == nil ? "Choose a dummy vault before turning on Face ID." : "Confirm your current pattern to save. Selecting a different dummy also requires its pattern. Enabling or removing Face ID protection requires a successful Face ID check.")
            }
        }
        .disabled(!loaded)
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle("Face ID & dummy vault").navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let settings = try await authenticator.settings(for: vault.id)
                available = try await authenticator.availableDummyVaults(for: vault.id)
                requireFaceID = settings.requiresFaceID == true
                dummyVaultID = settings.dummyVaultID
                originalDummyID = settings.dummyVaultID
                isDuressVault = settings.isDuressVault == true
                loaded = true
            } catch { self.error = error.localizedDescription }
        }
        .alert("Couldn’t load access settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { dismiss() }
        } message: { Text(error ?? "") }
    }
}

private struct FaceIDSettingsConfirmationView: View {
    let vault: Vault
    let requireFaceID: Bool
    let dummy: Vault?
    let needsDummyPattern: Bool
    let authenticator: PatternAuthenticator
    let completion: () -> Void
    @State private var faceID = FaceIDAuthenticator()
    @State private var currentPattern: [Int] = []
    @Environment(\.patternGridSize) private var gridSize
    @State private var isDrawing = false
    @State private var revision = 0
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    private var confirmingDummy: Bool { needsDummyPattern && !currentPattern.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: confirmingDummy ? "photo.on.rectangle" : "faceid")
                    .font(.system(size: 35, weight: .light)).foregroundStyle(AlbumTheme.accent)
                Text(confirmingDummy ? "Confirm the pattern for “\(dummy?.name ?? "")”" : "Confirm the pattern for “\(vault.name)”")
                    .font(.headline).multilineTextAlignment(.center)
                Text(confirmingDummy ? "This allows the selected vault to be shown without its pattern when Face ID fails or duress is used." : "This only updates settings. Confirming a duress pattern here does not activate duress.")
                    .font(.subheadline).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
                PatternGridView(side: 300, isEnabled: !busy, revision: revision, isDrawing: $isDrawing, completed: submit)
                if busy { ProgressView("Confirming access…") }
                if let error { Text(error).foregroundStyle(.red).multilineTextAlignment(.center).font(.subheadline) }
            }.padding(24).frame(maxWidth: .infinity)
        }
        .scrollDisabled(isDrawing)
        .background(AlbumTheme.background)
        .navigationTitle("Confirm access").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy)
        .onDisappear { operation?.cancel(); faceID.cancel(); currentPattern = [] }
    }

    private func submit(_ pattern: [Int]) {
        guard !busy else { return }
        revision += 1
        guard PatternRules.isValid(pattern, gridSize: gridSize) else { error = "Connect at least 4 different dots."; return }
        error = nil
        if needsDummyPattern && currentPattern.isEmpty { currentPattern = pattern; return }
        let sourcePattern = needsDummyPattern ? currentPattern : pattern
        let targetPattern = needsDummyPattern ? pattern : nil
        busy = true
        operation = Task {
            do {
                try await authenticator.setAccessSettings(vaultID: vault.id, requireFaceID: requireFaceID,
                    dummyVaultID: dummy?.id, currentPattern: sourcePattern, dummyPattern: targetPattern, faceID: faceID)
                if !Task.isCancelled { completion() }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; currentPattern = [] }
            }
            busy = false
        }
    }
}
