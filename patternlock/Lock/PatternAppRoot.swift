import Combine
import SwiftUI
import UIKit

struct PatternAppRoot: View {
    @State private var presentationRevision = 0
    @State private var lock = PatternLockStore()
    @State private var libraries = VaultLibraries.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if lock.stage == .unlocked, let vault = lock.unlockedVault {
                ContentView(store: libraries.store(for: vault), vaultName: vault.name,
                            createVault: lock.isDummySession ? nil : { libraries.dismissPresentations(); lock.beginNewVault() },
                            lockVault: { libraries.dismissPresentations(); lock.lock(); Task { await lock.activate() } },
                            vault: lock.isDummySession ? nil : vault,
                            onVaultChanged: { lock.updateUnlockedVault($0) },
                            onVaultDeleted: { libraries.forget(vault); lock.lock(); Task { await lock.activate() } })
                    .id(vault.id + "-" + String(presentationRevision))
            } else {
                PatternLockView(lock: lock)
            }
        }
        .transaction { transaction in
            if lock.stage != .unlocked { transaction.disablesAnimations = true }
        }
        // A separate window covers presented photos, pickers, and share sheets as
        // well as the root view before iOS takes its app-switcher snapshot.
        .background(ScenePrivacyShield(
            onInactive: { lock.becameInactive() },
            onBackground: { lock.enteredBackground(); libraries.dismissPresentations() },
            onActive: { await lock.activate() }
        ))
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: Task { await lock.activate() }
            case .inactive: lock.becameInactive()
            case .background: lock.enteredBackground(); libraries.dismissPresentations()
            @unknown default: lock.becameInactive()
            }
        }
        .task {
            await VaultBackup.shared.cleanTemporaryFilesOnce()
            try? await PatternAuthenticator.shared.cleanDeletedVaults(in: URL.applicationSupportDirectory.appending(path: "Vaults"))
        }
        .onReceive(NotificationCenter.default.publisher(for: VaultEvents.duressActivated).receive(on: RunLoop.main)) { notification in
            guard let activation = notification.object as? DuressActivation else { return }
            libraries.applyDuress(activation)
            presentationRevision += 1 // Dismiss sheets, previews, and pickers in every window.
            for id in activation.revokedVaultIDs {
                if lock.revokeAccess(to: id) { Task { await lock.activate() } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VaultEvents.accessRevoked).receive(on: RunLoop.main)) { notification in
            guard let vaultID = notification.object as? String else { return }
            if lock.revokeAccess(to: vaultID) {
                libraries.dismissPresentations()
                Task { await lock.activate() }
            }
        }
    }
}

struct ScenePrivacyShield: UIViewRepresentable {
    let onInactive: @MainActor () -> Void
    let onBackground: @MainActor () -> Void
    let onActive: @MainActor () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        context.coordinator.anchor = view
        context.coordinator.observe()
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.owner = self }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        var owner: ScenePrivacyShield
        weak var anchor: UIView?
        private var cover: UIWindow?
        private var observers: [NSObjectProtocol] = []
        private var activationTask: Task<Void, Never>?

        init(owner: ScenePrivacyShield) { self.owner = owner }

        func observe() {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.belongsToScene(notification) else { return }
                    self.activationTask?.cancel()
                    self.show()
                    self.owner.onInactive()
                }
            })
            observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.belongsToScene(notification) else { return }
                    self.show()
                    self.owner.onBackground()
                }
            })
            observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.belongsToScene(notification) else { return }
                    self.activationTask = Task { [weak self] in
                        guard let self else { return }
                        await self.owner.onActive()
                        // Let the lock view commit its layout before uncovering it.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        self.anchor?.window?.layoutIfNeeded()
                        self.cover?.isHidden = true
                        self.cover = nil
                    }
                }
            })
        }

        private func belongsToScene(_ notification: Notification) -> Bool {
            guard let scene = notification.object as? UIWindowScene else { return false }
            return scene === anchor?.window?.windowScene
        }

        private func show() {
            guard cover == nil, let scene = anchor?.window?.windowScene else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: PrivacyCover())
            window.isUserInteractionEnabled = true
            window.isHidden = false
            cover = window
        }

        func stop() {
            activationTask?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            cover?.isHidden = true
            cover = nil
        }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            AlbumTheme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock").font(.system(size: 32, weight: .light))
                Text("PATTERN").font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(4)
            }.foregroundStyle(AlbumTheme.accent)
        }.preferredColorScheme(.light)
    }
}
