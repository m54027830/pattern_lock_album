import SwiftUI

struct CloudBackupSettingsView: View {
    let vault: Vault
    let store: LibraryStore
    @State private var cloud = VaultCloudService.shared
    @State private var configuration: CloudBackupConfiguration?
    @State private var phrase = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var hasRecovery = false
    @State private var error: String?
    @State private var disabling = false

    var body: some View {
        Form {
            Section {
                Text(String(localized: "Keep an encrypted copy of this vault in your iCloud account. Photos, videos, folders, and names are encrypted before upload. Your recovery phrase is required to restore."))
                if let configuration {
                    LabeledContent(String(localized: "iCloud backup"), value: String(localized: "On"))
                    if let date = configuration.lastCompleted {
                        LabeledContent(String(localized: "Last completed backup"), value: date.formatted(date: .abbreviated, time: .shortened))
                    } else { Text(String(localized: "The first backup has not finished yet.")) }
                    Button(String(localized: "Back up now"), systemImage: "icloud.and.arrow.up") { run { try await cloud.synchronize(vault: vault, store: store, force: true) } }
                    Button(String(localized: "Turn off and delete cloud backup"), role: .destructive) { disabling = true }
                } else {
                    SecureField(String(localized: "This vault’s recovery phrase"), text: $phrase)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(!hasRecovery)
                    Button(String(localized: "Enable iCloud backup"), systemImage: "icloud.and.arrow.up") {
                        run { try await cloud.enableBackup(vault: vault, store: store, phrase: phrase); phrase = "" }
                    }.disabled(phrase.isEmpty || !loaded || !hasRecovery)
                }
                NavigationLink {
                    RestoreVaultView(authenticator: cloud.authenticator, offersFileImport: false)
                } label: {
                    Label(String(localized: "Restore from iCloud"), systemImage: "icloud.and.arrow.down")
                }
            } header: {
                Text(String(localized: "Encrypted iCloud backup"))
            } footer: {
                if loaded && !hasRecovery {
                    Text(String(localized: "Set up a recovery phrase in vault settings before enabling iCloud backup."))
                }
                Text(String(localized: "Backup is off until you enable it for this vault. While the vault is open, changes upload automatically. Reopen it to retry interrupted uploads. Keep your recovery phrase somewhere outside this phone."))
            }
            if busy || cloud.busyVaults.contains(vault.id) { Section { ProgressView(String(localized: "Updating iCloud…")) } }
            if let message = error ?? cloud.errors[vault.id] { Section { Text(message).foregroundStyle(.red) } }
            if let message = cloud.deletionError {
                Section {
                    Text(String(localized: "Cloud removal is pending. Pattern will retry when it can reach iCloud."))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button(String(localized: "Try again")) { run { await cloud.processDeletions() } }
                }
            }
        }
        .disabled(busy || cloud.busyVaults.contains(vault.id))
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "iCloud backup")).navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog(String(localized: "Delete this vault’s iCloud backup?"), isPresented: $disabling, titleVisibility: .visible) {
            Button(String(localized: "Turn off and delete cloud backup"), role: .destructive) { run { try await cloud.disableBackup(vaultID: vault.id) } }
        } message: { Text(String(localized: "The local vault stays on this device. Its cloud backup will be removed when iCloud is available, and future backups will stop.")) }
    }

    private func reload() async {
        do {
            let settings = try await cloud.authenticator.settings(for: vault.id)
            configuration = settings.cloudBackup
            hasRecovery = settings.recovery != nil
            loaded = true
        }
        catch { self.error = error.localizedDescription }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            await reload(); busy = false
        }
    }
}

struct VaultSharingSettingsView: View {
    let vault: Vault
    let store: LibraryStore
    @State private var cloud = VaultCloudService.shared
    @State private var purchases = PurchaseStore.shared
    @State private var shares: [OwnedVaultShare] = []
    @State private var label = ""
    @State private var expires = false
    @State private var expiry = Date.now.addingTimeInterval(7 * 86_400)
    @State private var limitsOpens = false
    @State private var maximumOpens = 10
    @State private var allowsExport = true
    @State private var blocksCapture = false
    @State private var phrase: String?
    @State private var busy = false
    @State private var error: String?
    @State private var showingPurchase = false
    @State private var revoking: OwnedVaultShare?

    var body: some View {
        Form {
            Section {
                Text(String(localized: "Give one person read-only access with a separate sharing phrase. They need Pattern and an iCloud account. Your pattern and recovery phrase stay private."))
                TextField(String(localized: "Recipient label (only on this device)"), text: $label)
                Toggle(String(localized: "Set an expiration date"), isOn: $expires)
                if expires { DatePicker(String(localized: "Expires"), selection: $expiry, in: Date.now...) }
                Toggle(String(localized: "Limit number of opens"), isOn: $limitsOpens)
                if limitsOpens { Stepper(String(localized: "Maximum opens: \(maximumOpens)"), value: $maximumOpens, in: 1...1000) }
                Toggle(String(localized: "Allow export"), isOn: $allowsExport)
                Toggle(String(localized: "Lock on screen capture"), isOn: $blocksCapture)
                Button(String(localized: "Create sharing phrase"), systemImage: "person.badge.plus") {
                    if !purchases.isUnlimited { showingPurchase = true }
                    else {
                        run {
                            phrase = try await cloud.createShare(vault: vault, store: store, label: label,
                                policy: VaultSharePolicy(expiresAt: expires ? expiry : nil, maximumOpens: limitsOpens ? maximumOpens : nil, allowsExport: allowsExport, blocksCapture: blocksCapture))
                        }
                    }
                }
            } header: { Text(String(localized: "Share this vault")) } footer: {
                Text(String(localized: "Creating shares requires Pattern Unlimited. Opening a shared vault is free. Each phrase can be claimed by one Apple Account. Create a separate phrase for each person."))
            }
            if let phrase {
                Section {
                    Text(phrase).font(.system(.body, design: .monospaced)).textSelection(.enabled).privacySensitive()
                    Button(String(localized: "Copy sharing phrase"), systemImage: "doc.on.doc") {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: phrase]], options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(300)])
                    }
                    Button(String(localized: "I saved the sharing phrase")) { self.phrase = nil }
                } footer: { Text(String(localized: "Send this phrase privately. Anyone who receives it before it is claimed can join. It will not be shown again after you leave this screen.")) }
            }
            if !shares.isEmpty {
                Section {
                    ForEach(shares) { share in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(share.label.isEmpty ? String(localized: "Shared vault") : share.label)
                            if let completed = share.lastCompleted { Text(completed.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                            Button(String(localized: "Revoke access"), role: .destructive) { revoking = share }
                        }
                    }
                    Button(String(localized: "Send latest changes")) { run { try await cloud.synchronize(vault: vault, store: store, force: true) } }
                } header: { Text(String(localized: "People with access")) }
            }
            Section {
                Text(String(localized: "Recipients check access online before opening. Updates are sent while your vault is open. Expiration, open limits, and export controls are app rules; they cannot erase saved copies. Screen capture detection can lock the vault after a screenshot, but cannot prevent that first screenshot or another camera."))
            }
            if busy { Section { ProgressView(String(localized: "Updating iCloud…")) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if cloud.deletionError != nil {
                Section {
                    Text(String(localized: "Revocation is pending. Pattern will retry when it can reach iCloud."))
                    Button(String(localized: "Try again")) { run { await cloud.processDeletions() } }
                }
            }
        }
        .disabled(busy || cloud.busyVaults.contains(vault.id))
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Sharing")).navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .sheet(isPresented: $showingPurchase) { PurchaseView() }
        .confirmationDialog(String(localized: "Revoke this person’s access?"), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            if let share = revoking {
                Button(String(localized: "Revoke access"), role: .destructive) { run { try await cloud.revoke(vaultID: vault.id, shareID: share.id); phrase = nil } }
            }
        } message: { Text(String(localized: "Revocation takes effect when iCloud receives it. Copies already saved outside Pattern cannot be removed.")) }
    }

    private func reload() async {
        do { shares = try await cloud.authenticator.settings(for: vault.id).ownedShares ?? [] }
        catch { self.error = error.localizedDescription }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            await reload(); busy = false
        }
    }
}

struct JoinSharedVaultView: View {
    var onJoined: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var name = ""
    @State private var prepared: PreparedVaultRestore?
    @State private var joined: JoinedVaultShare?
    @State private var busy = false
    @State private var installed = false
    @State private var error: String?

    var body: some View {
        Form {
            if installed {
                Section {
                    Label(String(localized: "Shared vault added"), systemImage: "checkmark.shield")
                    Text(String(localized: "Use your new pattern to open it. An internet connection is required to check access."))
                    Button(String(localized: "Done")) { onJoined?(); dismiss() }
                }
            } else if let prepared, let joined {
                Section {
                    Label(String(localized: "Read-only shared vault"), systemImage: "person.2")
                    TextField(String(localized: "Vault name"), text: $name)
                    Text(String(localized: "Files: \(prepared.snapshot.items.count) · Folders: \(prepared.snapshot.folders.count)"))
                    NavigationLink(String(localized: "Choose a pattern")) {
                        PatternSetupView(title: String(localized: "Shared vault pattern"), needsCurrentPattern: false) { _, pattern in
                            let vault = Vault(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                            try await PatternAuthenticator.shared.installRestoredVault(vault, pattern: pattern, preparedDirectory: prepared.directory, directory: URL.applicationSupportDirectory.appending(path: "Vaults"), lease: prepared.lease, joinedShare: joined)
                            self.prepared = nil; self.joined = nil; installed = true; phrase = ""
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Section {
                    Text(String(localized: "Enter the sharing phrase from the vault’s owner. This is different from a recovery phrase. Claiming ties the invitation to your current Apple Account."))
                    SecureField(String(localized: "Sharing phrase"), text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(String(localized: "Join shared vault"), systemImage: "person.badge.plus") {
                        busy = true; error = nil
                        Task {
                            do {
                                let result = try await VaultCloudService.shared.prepareJoin(phrase: phrase)
                                prepared = result.prepared; joined = result.joined; name = result.prepared.name; phrase = ""
                            } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.disabled(phrase.isEmpty || busy)
                }
                if busy { Section { ProgressView(String(localized: "Opening shared vault…")) } }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Join shared vault")).navigationBarTitleDisplayMode(.inline)
    }
}
