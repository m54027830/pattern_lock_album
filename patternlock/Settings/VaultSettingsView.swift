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
    @State private var appIcons = AppIconStore.shared
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
                    Button { name = vault.name; renaming = true } label: { valueRow(String(localized: "Vault name"), value: vault.name) }
                    valueRow(String(localized: "Files"), value: String(localized: "\(store.snapshot.items.count)"))
                    valueRow(String(localized: "Storage used"), value: storageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "Calculating…"))
                } header: { Text(String(localized: "Details")) }

                Section {
                    NavigationLink { PatternSetupView(title: String(localized: "Change pattern"), needsCurrentPattern: true) { current, replacement in
                        try await authenticator.changePattern(vaultID: vault.id, current: current, replacement: replacement)
                    } } label: { Label(String(localized: "Change pattern"), systemImage: "hand.draw") }
                    NavigationLink {
                        GridSizeSettingsView(authenticator: authenticator)
                    } label: {
                        valueRow(String(localized: "Pattern grid"), value: String(localized: "\(gridSize) × \(gridSize)"), icon: "circle.grid.3x3")
                    }
                } header: { Text(String(localized: "Pattern")) }

                Section {
                    NavigationLink {
                        FaceIDSettingsView(vault: vault, authenticator: authenticator) { revision += 1 }
                    } label: {
                        valueRow(String(localized: "Face ID & dummy vault"), value: requiresFaceID ? String(localized: "On") : String(localized: "Off"), icon: "faceid")
                    }
                } header: { Text(String(localized: "Access")) } footer: {
                    Text(String(localized: "Add Face ID after your pattern and choose which vault to show if it fails. Failed Face ID never activates duress."))
                }

                if !store.isReadOnly {
                    Section {
                        NavigationLink { CloudBackupSettingsView(vault: vault, store: store) } label: {
                            Label(String(localized: "iCloud backup"), systemImage: "lock.icloud")
                        }.disabled(backupsDisabled)
                        NavigationLink {
                            FileBackupSettingsView(store: store, vault: vault, authenticator: authenticator)
                        } label: {
                            Label(String(localized: "File backup"), systemImage: "lock.doc")
                        }.disabled(backupsDisabled)
                    } header: { Text(String(localized: "Encrypted Backup")) } footer: {
                        if backupsDisabled {
                            Text(String(localized: "Cloud backup and sharing are stopped on this device after a duress unlock."))
                        } else if !hasRecovery {
                            Text(String(localized: "Set up a recovery phrase in vault settings before enabling backup or exporting a file."))
                        }
                    }
                    Section {
                        NavigationLink { VaultSharingSettingsView(vault: vault, store: store) } label: {
                            Label(String(localized: "Share this vault"), systemImage: "person.2")
                        }.disabled(backupsDisabled)
                        NavigationLink { JoinSharedVaultView() } label: {
                            Label(String(localized: "Join shared vault"), systemImage: "person.badge.plus")
                        }.disabled(backupsDisabled)
                    } header: { Text(String(localized: "Sharing")) }
                } else {
                    Section {
                        Label(String(localized: "Read-only shared vault"), systemImage: "person.2")
                        Text(String(localized: "Only the owner can change the contents. Removing this vault from your device does not delete the owner’s vault."))
                    }
                }

                Section {
                    valueRow(String(localized: "Recovery phrase"), value: hasPendingRecovery ? String(localized: "New phrase ready") : hasRecovery ? String(localized: "Set up") : String(localized: "Not set up"))
                    if hasPendingRecovery {
                        NavigationLink {
                            PendingRecoveryPhraseView(vault: vault, authenticator: authenticator) { revision += 1 }
                        } label: { Label(String(localized: "Save new recovery phrase"), systemImage: "key") }
                    }
                    NavigationLink {
                        RecoveryPhraseSettingsView(vault: vault, generated: true, authenticator: authenticator) { revision += 1 }
                    } label: { Label(hasRecovery ? String(localized: "Regenerate recovery phrase") : String(localized: "Generate recovery phrase"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90") }
                    NavigationLink {
                        RecoveryPhraseSettingsView(vault: vault, generated: false, authenticator: authenticator) { revision += 1 }
                    } label: { Label(String(localized: "Set custom recovery phrase"), systemImage: "text.word.spacing") }
                } header: { Text(String(localized: "Recovery")) } footer: {
                    Text(String(localized: "A recovery phrase can reset a forgotten pattern. Keep it outside the app. After a duress unlock, save the new phrase here. Your previous phrase no longer opens this vault."))
                }

                if !store.isReadOnly { Section {
                    NavigationLink {
                        DuressSetupView(vault: vault, enabled: isDuressVault, authenticator: authenticator) { revision += 1 }
                    } label: {
                        valueRow(String(localized: "Use a duress vault"), value: isDuressVault ? String(localized: "On") : String(localized: "Off"), icon: "person.crop.rectangle")
                    }
                    Button(String(localized: "What’s this?"), systemImage: "questionmark.circle") { showDuressInfo = true }
                } header: { Text(String(localized: "Duress vault")) } }

                Section {
                    NavigationLink {
                        AppIconSettingsView(icons: appIcons)
                    } label: {
                        HStack(spacing: 12) {
                            AppIconPreview(icon: appIcons.selected, size: 32)
                            Text(String(localized: "App icon")).foregroundStyle(AlbumTheme.ink)
                            Spacer()
                            Text(appIcons.selected.title).foregroundStyle(AlbumTheme.secondary)
                        }
                    }
                    .accessibilityIdentifier("appIconSettings")
                } header: { Text(String(localized: "App settings")) }

                Section {
                    Button { showingPurchase = true } label: {
                        valueRow("Pattern Unlimited", value: purchases.isUnlimited ? String(localized: "Purchased") : String(localized: "Unlock once"), icon: "sparkles")
                    }
                    if !purchases.isUnlimited {
                        valueRow(String(localized: "Free album usage"), value: String(localized: "\(store.snapshot.items.count) / 5 items"))
                    }
                } header: { Text(String(localized: "Purchase")) } footer: {
                    Text(String(localized: "Free: 3 albums with 5 items each. One purchase removes both limits. No subscription."))
                }

                Section {
                    NavigationLink {
                        DeleteVaultView(vault: vault, store: store, authenticator: authenticator) { onDeleted(); dismiss() }
                    } label: { Label(String(localized: "Delete this vault"), systemImage: "trash").foregroundStyle(.red) }
                } footer: { Text(String(localized: "Deletes local files and credentials. For an owned vault, its configured cloud backup and shares are also removed when iCloud is available. Other vaults, Photos originals, and exported backup files remain.")) }
            }
            .disabled(!isLoaded || store.isBusy)
            .scrollContentBackground(.hidden).background(AlbumTheme.background)
            .navigationTitle(String(localized: "Vault settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
            .sheet(isPresented: $showingPurchase) { PurchaseView() }
            .task(id: revision) { await load() }
            .alert(String(localized: "Rename vault"), isPresented: $renaming) {
                TextField(String(localized: "Vault name"), text: $name)
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Save")) {
                    Task {
                        do { vault = try await authenticator.renameVault(vault.id, name: name); onVaultChanged(vault) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert(String(localized: "Duress vault"), isPresented: $showDuressInfo) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(DuressExplanation.summary + "\n\n" + DuressExplanation.limits)
            }
            .alert(String(localized: "Couldn’t update settings"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { error = nil }
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
    static let summary = String(localized: "Drawing this pattern removes access to your other vaults and stops cloud backup and sharing here. The selected dummy vault, or this vault, opens with a new recovery phrase. All owned shares are queued for revocation.")
    static let limits = String(localized: "Other vaults lose their local patterns and recovery phrases. Their files remain, but restoring access needs a saved backup. Share revocation retries when iCloud is available. Existing personal backups and copies already exported by recipients remain.")
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
                    Toggle(String(localized: "I understand that other vault access will be removed"), isOn: $understood)
                }
                NavigationLink(enabled ? String(localized: "Turn off duress vault") : String(localized: "Use this vault for duress")) {
                    PatternAuthorizationView(title: enabled ? String(localized: "Turn off duress vault") : String(localized: "Use as duress vault"), detail: enabled ? String(localized: "This stops future duress actions. It won’t restore access already removed or turn backups back on.") : String(localized: "Confirm this vault’s pattern to enable duress. The next time you use it to unlock Pattern, the actions above will happen.")) { pattern in
                        try await authenticator.setDuressVault(vaultID: vault.id, enabled: !enabled, currentPattern: pattern)
                        completion(); dismiss()
                    }
                }.disabled(!enabled && !understood)
            } footer: {
                Text(enabled ? String(localized: "If this vault survives, each unlock with its duress pattern repeats the action. If a different dummy is selected, only the dummy vault survives.") : String(localized: "Enabling this setting doesn’t activate it immediately. You can keep adding everyday photos here before locking the app."))
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Duress vault")).navigationBarTitleDisplayMode(.inline)
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
                Label(String(localized: "This cannot be undone"), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Text(String(localized: "Delete “\(vault.name)” and all its files (\(store.snapshot.items.count)), its pattern, and its recovery phrase from this device. Other vaults and originals in Photos stay. Backups saved in Files must be deleted separately."))
                if !store.isReadOnly {
                    Text(String(localized: "Deletes local files and credentials. For an owned vault, its configured cloud backup and shares are also removed when iCloud is available. Other vaults, Photos originals, and exported backup files remain."))
                }
                TextField(String(localized: "Type \(vault.name) to confirm"), text: $confirmation).autocorrectionDisabled()
            }
            Section {
                NavigationLink {
                    PatternAuthorizationView(title: String(localized: "Delete this vault"), detail: String(localized: "Drawing this vault’s current pattern will permanently delete it.")) { pattern in
                        try await store.withExclusiveAccess {
                            try await authenticator.deleteVault(vaultID: vault.id, currentPattern: pattern, directory: store.repository.root.deletingLastPathComponent())
                            store.invalidateDeletedVault()
                        }
                        completion()
                    }
                } label: { Text(String(localized: "Confirm pattern and delete")).foregroundStyle(.red) }
                .disabled(confirmation != vault.name || store.isBusy)
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Delete this vault")).navigationBarTitleDisplayMode(.inline)
    }
}
