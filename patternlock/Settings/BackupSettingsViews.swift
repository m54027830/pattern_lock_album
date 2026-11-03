import SwiftUI
import UniformTypeIdentifiers

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
                Label(String(localized: "Encrypted backup"), systemImage: "lock.icloud")
                Text(String(localized: "Your photos, videos, folders, and vault name are encrypted before saving. Choose iCloud Drive in Files to keep the backup in iCloud."))
                SecureField(String(localized: "This vault’s recovery phrase"), text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text(String(localized: "Save the phrase separately and wait for iCloud Drive to finish uploading before deleting Pattern. Deleting the app removes local vaults. Restoration needs both the backup file and its original phrase.")) }
            Section {
                Button(String(localized: "Back up now"), systemImage: "icloud.and.arrow.up", action: createBackup).disabled(phrase.isEmpty || busy || store.isBusy)
                if busy { ProgressView(String(localized: "Encrypting backup…")) }
                if saved { Label(String(localized: "Backup saved through Files"), systemImage: "checkmark.circle").foregroundStyle(AlbumTheme.accent) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Back up vault")).navigationBarTitleDisplayMode(.inline)
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
    var authenticator = PatternAuthenticator.shared
    var onRestored: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var selectingFile = false
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
                    Label(String(localized: "Restore from iCloud Drive"), systemImage: "lock.icloud")
                    Text(String(localized: "In Files, open Browse → iCloud Drive and select your saved .patternbackup file. Sign in to the same Apple Account and turn on iCloud Drive if it isn’t listed."))
                    Button(url == nil ? String(localized: "Choose iCloud backup") : String(localized: "Choose another backup"), systemImage: "icloud.and.arrow.down") { selectingFile = true }
                    if let url { Text(url.lastPathComponent).font(.caption).foregroundStyle(AlbumTheme.secondary) }
                    SecureField(String(localized: "Phrase used for this backup"), text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(String(localized: "Open encrypted backup"), action: prepare).disabled(url == nil || phrase.isEmpty || busy)
                    if busy { ProgressView(String(localized: "Opening backup…")) }
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: { Text(String(localized: "You need a backup saved before the app was deleted and the recovery phrase used to encrypt it. A recovery phrase alone cannot restore deleted photos or videos.")) }
            }
        }
        .disabled(busy)
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Restore from iCloud")).navigationBarTitleDisplayMode(.inline)
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
    }

    private func prepare() {
        guard let url else { return }
        busy = true; error = nil
        operation = Task {
            do {
                let value = try await VaultBackup.shared.prepareRestore(from: url, phrase: phrase, security: authenticator.security)
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
                } footer: { Text(String(localized: "This resets a pattern for a vault still on this device. After deleting and reinstalling Pattern, use Restore from iCloud instead; you’ll need your saved backup file and its phrase.")) }
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
