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
                Label("Encrypted backup", systemImage: "lock.icloud")
                Text("Your photos, videos, folders, and vault name are encrypted before saving. Choose iCloud Drive in Files to keep the backup in iCloud.")
                SecureField("This vault’s recovery phrase", text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text("Save the phrase separately. Pattern can’t recover an encrypted backup without the phrase used to create it.") }
            Section {
                Button("Back up now", systemImage: "icloud.and.arrow.up", action: createBackup).disabled(phrase.isEmpty || busy || store.isBusy)
                if busy { ProgressView("Encrypting backup…") }
                if saved { Label("Backup saved through Files", systemImage: "checkmark.circle").foregroundStyle(AlbumTheme.accent) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle("Back up vault").navigationBarTitleDisplayMode(.inline)
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
                    Label("Backup opened", systemImage: "checkmark.shield")
                    Text("\(prepared.snapshot.items.count) files · \(prepared.snapshot.folders.count) folders")
                    TextField("New vault name", text: $name)
                } footer: { Text("Restore creates a separate vault and keeps all existing vaults. Choose a unique name and pattern. After restoring, generate a new recovery phrase in its settings.") }
                Section {
                    NavigationLink("Choose a pattern and restore") {
                        PatternSetupView(title: "Restored vault pattern", needsCurrentPattern: false) { _, pattern in
                            _ = try await VaultBackup.shared.install(prepared, name: name, pattern: pattern, authenticator: authenticator)
                            self.prepared = nil
                            restored = true
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if restored {
                Section {
                    Label("Vault restored", systemImage: "checkmark.circle")
                    Text("Lock Pattern, then draw the new pattern to open the restored vault.")
                    Button("Done") { onRestored?(); dismiss() }
                }
            } else {
                Section {
                    Button(url == nil ? "Choose backup from Files" : "Choose another backup", systemImage: "folder") { selectingFile = true }
                    if let url { Text(url.lastPathComponent).font(.caption).foregroundStyle(AlbumTheme.secondary) }
                    SecureField("Phrase used for this backup", text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Open encrypted backup", action: prepare).disabled(url == nil || phrase.isEmpty || busy)
                    if busy { ProgressView("Opening backup…") }
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: { Text("Choose a .patternbackup file from iCloud Drive or another Files location. If you changed your phrase, older backups still use the old phrase.") }
            }
        }
        .disabled(busy)
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle("Restore backup").navigationBarTitleDisplayMode(.inline)
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
                else { prepared = value; name = String((value.name + " restored").prefix(40)); phrase = "" }
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
                    Label("Pattern changed", systemImage: "checkmark.shield")
                    Text("Use your new pattern to unlock the vault.")
                    Button("Return to lock screen", action: completion)
                }
            } else {
                Section {
                    SecureField("Recovery phrase", text: $phrase).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text("Enter the phrase for the vault you want to recover. Your files stay in place.") }
                Section {
                    NavigationLink("Choose a new pattern") {
                        PatternSetupView(title: "Reset pattern", needsCurrentPattern: false) { _, pattern in
                            _ = try await PatternAuthenticator.shared.recover(phrase: phrase, newPattern: pattern)
                            phrase = ""; recovered = true
                        }
                    }.disabled(phrase.isEmpty)
                }
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle("Recover vault").navigationBarTitleDisplayMode(.inline)
    }
}
