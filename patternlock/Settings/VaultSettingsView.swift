import SwiftUI

struct VaultSettingsView: View {
    @Bindable var store: LibraryStore
    @State var vault: Vault
    let onVaultChanged: (Vault) -> Void
    let onDeleted: () -> Void
    var authenticator = PatternAuthenticator.shared
    @Environment(\.patternGridSize) private var gridSize
    @Environment(\.dismiss) private var dismiss
    @State private var purchases = PurchaseStore.shared
    @State private var showingPurchase = false
    @State private var storageBytes: Int64?
    @State private var hasRecovery = false
    @State private var isDuressVault = false
    @State private var requiresFaceID = false
    @State private var backupsDisabled = false
    @State private var hasPendingRecovery = false
    @State private var isLoaded = false
    @State private var error: String?
    @State private var name = ""
    @State private var renaming = false
    @State private var showDuressInfo = false
    @State private var revision = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { name = vault.name; renaming = true } label: { valueRow("Vault name", value: vault.name) }
                    valueRow("Files", value: "\(store.snapshot.items.count)")
                    valueRow("Storage used", value: storageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                } header: { Text("Details") }

                Section {
                    NavigationLink { PatternSetupView(title: "Change pattern", needsCurrentPattern: true) { current, replacement in
                        try await authenticator.changePattern(vaultID: vault.id, current: current, replacement: replacement)
                    } } label: { Label("Change pattern", systemImage: "hand.draw") }
                    NavigationLink {
                        GridSizeSettingsView(authenticator: authenticator)
                    } label: {
                        valueRow("Pattern grid", value: "\(gridSize) × \(gridSize)", icon: "circle.grid.3x3")
                    }
                } header: { Text("Pattern") }

                Section {
                    NavigationLink {
                        FaceIDSettingsView(vault: vault, authenticator: authenticator) { revision += 1 }
                    } label: {
                        valueRow("Face ID & dummy vault", value: requiresFaceID ? "On" : "Off", icon: "faceid")
                    }
                } header: { Text("Access") } footer: {
                    Text("Add Face ID after your pattern and choose which vault to show if it fails. Failed Face ID never activates duress.")
                }

                Section {
                    valueRow("Backups on this device", value: backupsDisabled ? "Off" : "Available", icon: "icloud")
                    valueRow("Encrypt backup", value: "Always on", icon: "lock.shield")
                    NavigationLink { BackupExportView(store: store, vault: vault, authenticator: authenticator) } label: {
                        Label("Back up to iCloud Drive", systemImage: "icloud.and.arrow.up")
                    }.disabled(!hasRecovery || backupsDisabled)
                    NavigationLink { RestoreVaultView(authenticator: authenticator) } label: {
                        Label("Restore a backup", systemImage: "icloud.and.arrow.down")
                    }
                } header: { Text("Backup") } footer: {
                    Text(backupsDisabled ? "Duress unlock turned off backups from Pattern on this device, including future device backups of local vault files. Saved backups remain in Files. This version doesn’t use automatic iCloud sync." : hasRecovery ? "Save an encrypted backup through Files and choose iCloud Drive. You’ll need your recovery phrase to open it. Backups are manual; they don’t sync automatically." : "Set up a recovery phrase below to make encrypted backups. You can save them to iCloud Drive through Files.")
                }

                Section {
                    valueRow("Recovery phrase", value: hasPendingRecovery ? "New phrase ready" : hasRecovery ? "Set up" : "Not set up")
                    if hasPendingRecovery {
                        NavigationLink {
                            PendingRecoveryPhraseView(vault: vault, authenticator: authenticator) { revision += 1 }
                        } label: { Label("Save new recovery phrase", systemImage: "key") }
                    }
                    NavigationLink {
                        RecoveryPhraseSettingsView(vault: vault, generated: true, authenticator: authenticator) { revision += 1 }
                    } label: { Label(hasRecovery ? "Regenerate recovery phrase" : "Generate recovery phrase", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") }
                    NavigationLink {
                        RecoveryPhraseSettingsView(vault: vault, generated: false, authenticator: authenticator) { revision += 1 }
                    } label: { Label("Set custom recovery phrase", systemImage: "text.word.spacing") }
                } header: { Text("Recovery") } footer: {
                    Text("A recovery phrase can reset a forgotten pattern. Keep it outside the app. After a duress unlock, save the new phrase here. Your previous phrase no longer opens this vault.")
                }

                Section {
                    NavigationLink {
                        DuressSetupView(vault: vault, enabled: isDuressVault, authenticator: authenticator) { revision += 1 }
                    } label: {
                        valueRow("Use a duress vault", value: isDuressVault ? "On" : "Off", icon: "person.crop.rectangle")
                    }
                    Button("What’s this?", systemImage: "questionmark.circle") { showDuressInfo = true }
                } header: { Text("Duress vault") }

                Section {
                    Button { showingPurchase = true } label: {
                        valueRow("Pattern Unlimited", value: purchases.isUnlimited ? "Purchased" : "Unlock once", icon: "sparkles")
                    }
                    if !purchases.isUnlimited {
                        valueRow("Free album usage", value: "\(store.snapshot.items.count) / 5 photos/videos")
                    }
                } header: { Text("Purchase") } footer: {
                    Text("Free: 3 albums with 5 photos or videos each. One purchase removes both limits. No subscription.")
                }

                Section {
                    NavigationLink {
                        DeleteVaultView(vault: vault, store: store, authenticator: authenticator) { onDeleted(); dismiss() }
                    } label: { Label("Delete this vault", systemImage: "trash").foregroundStyle(.red) }
                } footer: { Text("Deletes this vault’s local files and access credentials. Other vaults, Photos originals, and saved backup files remain.") }
            }
            .disabled(!isLoaded || store.isBusy)
            .scrollContentBackground(.hidden).background(AlbumTheme.background)
            .navigationTitle("Vault settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingPurchase) { PurchaseView() }
            .task(id: revision) { await load() }
            .alert("Rename vault", isPresented: $renaming) {
                TextField("Vault name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    Task {
                        do { vault = try await authenticator.renameVault(vault.id, name: name); onVaultChanged(vault) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert("Duress vault", isPresented: $showDuressInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(DuressExplanation.summary + "\n\n" + DuressExplanation.limits)
            }
            .alert("Couldn’t update settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(AlbumTheme.accent)
    }

    private func valueRow(_ title: String, value: String, icon: String? = nil) -> some View {
        HStack {
            if let icon { Image(systemName: icon).foregroundStyle(AlbumTheme.accent).frame(width: 24) }
            Text(title).foregroundStyle(AlbumTheme.ink)
            Spacer()
            Text(value).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func load() async {
        do {
            let settings = try await authenticator.settings(for: vault.id)
            hasRecovery = settings.recovery != nil
            isDuressVault = settings.isDuressVault == true
            requiresFaceID = settings.requiresFaceID == true
            hasPendingRecovery = settings.pendingRecoveryPhrase != nil
            backupsDisabled = try await authenticator.backupsAreDisabled()
            storageBytes = try await store.repository.storageUsed()
            isLoaded = true
        } catch { self.error = error.localizedDescription }
    }
}

private enum DuressExplanation {
    static let summary = "Drawing this vault’s pattern removes access to every vault except the one displayed and stops backups here. Your selected dummy vault opens, or this vault if no dummy is set. The surviving vault gets a new recovery phrase and active sharing closes."
    static let limits = "Other vaults’ patterns and recovery phrases are removed from this device, including this vault’s if a different dummy vault is selected. Their local files are kept, but you’ll need a saved backup to restore access in Pattern. Already saved iCloud backups and copies sent to others can’t be recalled. Automatic iCloud sync and revocable share links aren’t available in this version."
}

private struct DuressSetupView: View {
    let vault: Vault
    let enabled: Bool
    let authenticator: PatternAuthenticator
    let completion: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false

    var body: some View {
        Form {
            Section {
                Label(vault.name, systemImage: "person.crop.rectangle")
                Text(DuressExplanation.summary)
            } footer: { Text(DuressExplanation.limits) }
            Section {
                if !enabled {
                    Toggle("I understand that other vault access will be removed", isOn: $understood)
                }
                NavigationLink(enabled ? "Turn off duress vault" : "Use this vault for duress") {
                    PatternAuthorizationView(title: enabled ? "Turn off duress vault" : "Use as duress vault", detail: enabled ? "This stops future duress actions. It won’t restore access already removed or turn backups back on." : "Confirm this vault’s pattern to enable duress. The next time you use it to unlock Pattern, the actions above will happen.") { pattern in
                        try await authenticator.setDuressVault(vaultID: vault.id, enabled: !enabled, currentPattern: pattern)
                        completion(); dismiss()
                    }
                }.disabled(!enabled && !understood)
            } footer: {
                Text(enabled ? "If this vault survives, each unlock with its duress pattern repeats the action. If a different dummy is selected, only the dummy vault survives." : "Enabling this setting doesn’t activate it immediately. You can keep adding everyday photos here before locking the app.")
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle("Duress vault").navigationBarTitleDisplayMode(.inline)
    }
}

private struct DeleteVaultView: View {
    let vault: Vault
    let store: LibraryStore
    let authenticator: PatternAuthenticator
    let completion: () -> Void
    @State private var confirmation = ""

    var body: some View {
        Form {
            Section {
                Label("This cannot be undone", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Text("Delete “\(vault.name)”, its \(store.snapshot.items.count) files, its pattern, and its recovery phrase from this device. Other vaults and originals in Photos stay. Backups saved in Files must be deleted separately.")
                TextField("Type \(vault.name) to confirm", text: $confirmation).autocorrectionDisabled()
            }
            Section {
                NavigationLink {
                    PatternAuthorizationView(title: "Delete this vault", detail: "Drawing this vault’s current pattern will permanently delete it.") { pattern in
                        try await store.withExclusiveAccess {
                            try await authenticator.deleteVault(vaultID: vault.id, currentPattern: pattern, directory: store.repository.root.deletingLastPathComponent())
                            store.invalidateDeletedVault()
                        }
                        completion()
                    }
                } label: { Text("Confirm pattern and delete").foregroundStyle(.red) }
                .disabled(confirmation != vault.name || store.isBusy)
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle("Delete this vault").navigationBarTitleDisplayMode(.inline)
    }
}
