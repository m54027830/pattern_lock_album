import SwiftUI
import UniformTypeIdentifiers

struct FileBackupSettingsView: View {
    let store: LibraryStore
    let vault: Vault
    let authenticator: PatternAuthenticator
    @State private var hasRecovery = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text(String(localized: "Save an encrypted backup file to iCloud Drive or another location in Files. Export again to include newer changes. Import requires the file and its original recovery phrase."))
                NavigationLink {
                    BackupExportView(store: store, vault: vault, authenticator: authenticator)
                } label: {
                    Label(String(localized: "Export backup file"), systemImage: "arrow.up.doc")
                }.disabled(!loaded || !hasRecovery)
                NavigationLink {
                    RestoreVaultView(authenticator: authenticator, source: .file)
                } label: {
                    Label(String(localized: "Import a backup file"), systemImage: "arrow.down.doc")
                }
            } footer: {
                if loaded && !hasRecovery {
                    Text(String(localized: "Set up a recovery phrase in vault settings before exporting a file."))
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "File backup")).navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                hasRecovery = try await authenticator.settings(for: vault.id).recovery != nil
                loaded = true
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct BackupExportView: View {
    let store: LibraryStore
    let vault: Vault
    let authenticator: PatternAuthenticator
    @State private var phrase = ""
    @State private var export: BackupExport?
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Label(String(localized: "Encrypted backup"), systemImage: "lock.doc")
                Text(String(localized: "Your photos, videos, folders, and vault name are encrypted before saving. Choose iCloud Drive in Files to keep the backup in iCloud."))
                SecureField(String(localized: "This vault’s recovery phrase"), text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text(String(localized: "Save the phrase separately and wait for iCloud Drive to finish uploading before deleting Pattern. Deleting the app removes local vaults. Restoration needs both the backup file and its original phrase.")) }
            Section {
                Button(String(localized: "Export backup file"), systemImage: "arrow.up.doc", action: createBackup).disabled(phrase.isEmpty || busy || store.isBusy)
                if busy { ProgressView(String(localized: "Encrypting backup…")) }
                if saved { Label(String(localized: "Backup saved through Files"), systemImage: "checkmark.circle").foregroundStyle(AlbumTheme.accent) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Export backup file")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $export, onDismiss: cleanup) { backup in
            BackupFileExporter(url: backup.url) { didSave in saved = didSave; export = nil; cleanupURL(backup.url) }
                .ignoresSafeArea()
        }
        .onDisappear { operation?.cancel(); phrase = ""; cleanup() }
    }

    private func createBackup() {
        busy = true; error = nil; saved = false
        operation = Task {
            do {
                let lease = try authenticator.security.lease(for: vault.id)
                try authenticator.security.check(lease, forBackup: true)
                let url = try await store.withExclusiveAccess {
                    try await authenticator.validateRecoveryPhrase(vaultID: vault.id, phrase: phrase)
                    try Task.checkCancellation()
                    return try await VaultBackup.shared.create(name: vault.name, snapshot: store.snapshot, root: store.repository.root, phrase: phrase, security: authenticator.security)
                }
                if Task.isCancelled || (try? authenticator.security.check(lease, forBackup: true)) == nil { cleanupURL(url) }
                else { export = BackupExport(url: url); phrase = "" }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            busy = false
        }
    }

    private func cleanupURL(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    private func cleanup() { if let export { cleanupURL(export.url) }; export = nil }
}

private struct BackupExport: Identifiable { let id = UUID(); let url: URL }

private struct BackupFileExporter: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(!urls.isEmpty) }
    }
}

struct RestoreVaultView: View {
    enum Source { case iCloud, file }

    var authenticator = PatternAuthenticator.shared
    var onRestored: (() -> Void)?
    var source: Source = .iCloud
    var offersFileImport = true
    @Environment(\.dismiss) private var dismiss
    @State private var selectingFile = false
    @State private var backups: [CloudBackupSummary] = []
    @State private var selectedBackup: String?
    @State private var listing = false
    @State private var url: URL?
    @State private var phrase = ""
    @State private var prepared: PreparedVaultRestore?
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var restored = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Form {
            if let prepared {
                Section {
                    Label(String(localized: "Backup opened"), systemImage: "checkmark.shield")
                    Text(String(localized: "Files: \(prepared.snapshot.items.count) · Folders: \(prepared.snapshot.folders.count)"))
                    TextField(String(localized: "New vault name"), text: $name)
                } footer: { Text(String(localized: "Restore creates a separate vault and keeps all existing vaults. Choose a unique name and pattern. After restoring, generate a new recovery phrase in its settings.")) }
                Section {
                    NavigationLink(String(localized: "Choose a pattern and restore")) {
                        PatternSetupView(title: String(localized: "Restored vault pattern"), needsCurrentPattern: false) { _, pattern in
                            _ = try await VaultBackup.shared.install(prepared, name: name, pattern: pattern, authenticator: authenticator)
                            self.prepared = nil
                            restored = true
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if restored {
                Section {
                    Label(String(localized: "Vault restored"), systemImage: "checkmark.circle")
                    Text(String(localized: "Draw your new pattern on the lock screen to open the restored vault."))
                    Button(String(localized: "Done")) { onRestored?(); dismiss() }
                }
            } else {
                Section {
                    if source == .file {
                        Text(String(localized: "Previously exported .patternbackup files can still be restored with their original recovery phrases."))
                        Button(String(localized: "Import a backup file"), systemImage: "arrow.down.doc") { selectingFile = true }
                        if let url { Text(url.lastPathComponent).font(.caption).foregroundStyle(AlbumTheme.secondary) }
                    } else {
                        Label(String(localized: "Restore from iCloud"), systemImage: "lock.icloud")
                        Text(String(localized: "Sign in to the Apple Account that owns the backup, choose a saved backup, and enter its recovery phrase."))
                        if listing { ProgressView(String(localized: "Looking for backups…")) }
                        else if backups.isEmpty && error == nil { Text(String(localized: "No cloud backups found. A backup must have completed before the app was deleted.")) }
                        else if !backups.isEmpty {
                            Picker(String(localized: "Backup"), selection: $selectedBackup) {
                                Text(String(localized: "Choose a backup")).tag(String?.none)
                                ForEach(Array(backups.enumerated()), id: \.element.id) { index, backup in
                                    Text(String(localized: "Backup") + " " + String(index + 1) + " · " + backup.date.formatted(date: .abbreviated, time: .shortened)).tag(Optional(backup.id))
                                }
                            }
                        }
                        Button(String(localized: "Refresh backups")) { Task { await listBackups() } }.disabled(listing)
                    }
                    SecureField(String(localized: "Phrase used for this backup"), text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(String(localized: "Open encrypted backup"), action: prepare).disabled((source == .file ? url == nil : selectedBackup == nil) || phrase.isEmpty || busy)
                    if busy { ProgressView(String(localized: "Opening backup…")) }
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: {
                    if source == .iCloud {
                        Text(String(localized: "Cloud backups are encrypted before upload. Only the recovery phrase used for the latest completed backup can open it. Your pattern alone cannot restore deleted files."))
                    }
                }
                // Keep file restoration reachable from onboarding and the lock
                // screen. Settings already provides its own File backup section.
                if source == .iCloud && offersFileImport {
                    Section {
                        NavigationLink {
                            RestoreVaultView(authenticator: authenticator, onRestored: onRestored, source: .file)
                        } label: {
                            Label(String(localized: "Import a backup file"), systemImage: "arrow.down.doc")
                        }
                    } header: { Text(String(localized: "File backup")) }
                }

            }
        }
        .disabled(busy)
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(source == .file ? String(localized: "Import a backup file") : String(localized: "Restore from iCloud")).navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $selectingFile, allowedContentTypes: [.data]) { result in
            do { url = try result.get(); error = nil }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear {
            // A pushed pattern screen still needs the prepared files. The restore
            // object's deinitializer removes them when navigation releases it.
            if busy { operation?.cancel() }
        }
        .onChange(of: restored) { _, done in if done { phrase = "" } }
        .task { if source == .iCloud { await listBackups() } }
    }

    private func listBackups() async {
        listing = true; error = nil
        defer { listing = false }
        do {
            backups = try await VaultCloudService.shared.listBackups()
            if selectedBackup == nil, backups.count == 1 { selectedBackup = backups.first?.id }
        } catch { self.error = error.localizedDescription }
    }

    private func prepare() {
        busy = true; error = nil
        operation = Task {
            do {
                let value: PreparedVaultRestore
                switch source {
                case .file:
                    guard let url else { throw VaultCloudError.invalidData }
                    value = try await VaultBackup.shared.prepareRestore(from: url, phrase: phrase, security: authenticator.security)
                case .iCloud:
                    guard let id = selectedBackup else { throw VaultCloudError.invalidData }
                    value = try await VaultCloudService.shared.prepareBackup(id: id, phrase: phrase)
                }
                if Task.isCancelled { try? FileManager.default.removeItem(at: value.directory) }
                else { prepared = value; name = String(String(localized: "\(value.name) restored").prefix(40)); phrase = "" }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            busy = false
        }
    }
}

struct RecoverPatternView: View {
    @State private var phrase = ""
    @State private var recovered = false
    let completion: () -> Void
    var body: some View {
        Form {
            if recovered {
                Section {
                    Label(String(localized: "Pattern changed"), systemImage: "checkmark.shield")
                    Text(String(localized: "Use your new pattern to unlock the vault."))
                    Button(String(localized: "Return to lock screen"), action: completion)
                }
            } else {
                Section {
                    SecureField(String(localized: "Recovery phrase"), text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text(String(localized: "This resets a pattern for a vault still on this device. After reinstalling Pattern, use Restore from iCloud with a completed backup and its recovery phrase.")) }
                Section {
                    NavigationLink(String(localized: "Choose a new pattern")) {
                        PatternSetupView(title: String(localized: "Reset pattern"), needsCurrentPattern: false) { _, pattern in
                            _ = try await PatternAuthenticator.shared.recover(phrase: phrase, newPattern: pattern)
                            phrase = ""; recovered = true
                        }
                    }.disabled(phrase.isEmpty)
                }
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Recover vault")).navigationBarTitleDisplayMode(.inline)
    }
}
