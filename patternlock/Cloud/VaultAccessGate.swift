import SwiftUI

/// A shared library is never mounted until its online access check succeeds.
/// The privacy window still covers this view and all presented media on lock.
struct VaultAccessGate<Content: View>: View {
    let vault: Vault
    let store: LibraryStore
    let sessionScope: UUID
    var isDummy = false
    let lock: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.isSceneCaptured) private var captureState
    @State private var ready = false
    @State private var joined: JoinedVaultShare?
    @State private var session: SharedVaultSession?
    @State private var error: String?
    @State private var revision = 0

    var body: some View {
        Group {
            if ready && session?.error == nil { content() }
            else {
                VStack(spacing: 20) {
                    if let error = session?.error ?? error {
                        Image(systemName: "lock.icloud").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center)
                        Button(String(localized: "Try again")) { revision += 1 }
                    } else { ProgressView(String(localized: "Checking vault access…")) }
                    Button(String(localized: "Lock vault"), action: lock)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(AlbumTheme.background)
            }
        }
        .task(id: revision) {
            if ready && session?.error == nil { return }
            VaultCloudService.shared.stopViewingSession(session)
            session = nil
            ready = false; error = nil
            do {
                if isDummy { ready = true; return }
                joined = try await VaultCloudService.shared.openShared(vault: vault, store: store)
                try Task.checkCancellation()
                if joined?.policy.blocksCapture == true, captureState { lock(); return }
                ready = true
                guard let joined else { return }
                session = VaultCloudService.shared.monitor(joined, scope: sessionScope)
            } catch {
                guard !Task.isCancelled else { return }
                ready = false
                store.finishExport()
                self.error = error.localizedDescription
            }
        }
        .onChange(of: session?.error) { _, error in
            if error != nil { store.finishExport() }
        }
        .onChange(of: captureState) { _, value in
            if value && joined?.policy.blocksCapture == true { ready = false; store.finishExport(); lock() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if joined?.policy.blocksCapture == true { ready = false; store.finishExport(); lock() }
        }
    }
}
