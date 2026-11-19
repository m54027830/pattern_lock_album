import Combine
import SwiftUI
import UIKit

struct PatternAppRoot: View {
    @State private var presentationRevision = 0
    @State private var cloudSessionScope = UUID()
    @State private var purchases = PurchaseStore.shared
    @State private var purchaseLimit: FreeTierLimit?
    @State private var lock = PatternLockStore()
    @State private var libraries = VaultLibraries.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if lock.stage == .loading {
                // Registration is still unknown. Never flash the returning-user
                // lock screen before deciding whether onboarding is needed.
                PrivacyCover()
                    .accessibilityIdentifier("initialLoadingScreen")
            } else if lock.stage == .unlocked, let vault = lock.unlockedVault {
                VaultAccessGate(vault: vault, store: libraries.store(for: vault), sessionScope: cloudSessionScope, isDummy: lock.isDummySession, lock: { libraries.dismissPresentations(); lock.lock(); Task { await lock.activate() } }) {
                ContentView(store: libraries.store(for: vault), vaultName: vault.name,
                            createVault: lock.isDummySession ? nil : { beginNewVault(from: vault) },
                            lockVault: { libraries.dismissPresentations(); lock.lock(); Task { await lock.activate() } },
                            vault: lock.isDummySession ? nil : vault,
                            onVaultChanged: { lock.updateUnlockedVault($0) },
                            onVaultDeleted: { libraries.forget(vault); lock.lock(); Task { await lock.activate(); await VaultCloudService.shared.processDeletions() } })
                }
                    .id(vault.id + "-" + String(presentationRevision))
            } else if lock.stage == .onboarding {
                OnboardingView(onRestored: { lock.lock(); Task { await lock.activate() } }) { name, pattern, size, phrase in
                    try await lock.finishOnboarding(name: name, pattern: pattern, gridSize: size, recoveryPhrase: phrase)
                }
            } else {
                PatternLockView(lock: lock)
            }
        }
        .tint(AlbumTheme.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if lock.stage != .loading && lock.stage != .onboarding && lock.stage != .unlocked { SpecialOfferBanner() }
        }
        .environment(\.patternGridSize, lock.gridSize)
        .onChange(of: lock.stage) { _, stage in
            if stage != .unlocked { VaultCloudService.shared.stopViewingSessions(scope: cloudSessionScope) }
        }
        .transaction { transaction in
            if lock.stage != .unlocked && lock.stage != .onboarding { transaction.disablesAnimations = true }
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
            case .active: Task { await lock.activate(); await purchases.refreshEntitlements(); await VaultCloudService.shared.processDeletions() }
            case .inactive: lock.becameInactive()
            case .background: purchaseLimit = nil; lock.enteredBackground(); libraries.dismissPresentations()
            @unknown default: lock.becameInactive()
            }
        }
        .purchaseOffer(item: $purchaseLimit)
        .task { await purchases.start() }
        .task {
            VaultFileDraft.cleanTemporaryFilesOnce()
            await VaultBackup.shared.cleanTemporaryFilesOnce()
            try? await PatternAuthenticator.shared.cleanDeletedVaults(in: URL.applicationSupportDirectory.appending(path: "Vaults"))
        }
        .onReceive(NotificationCenter.default.publisher(for: VaultEvents.gridChanged).receive(on: RunLoop.main)) { _ in
            purchaseLimit = nil
            libraries.dismissPresentations()
            lock.lock()
            Task { await lock.activate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: VaultEvents.duressActivated).receive(on: RunLoop.main)) { notification in
            guard let activation = notification.object as? DuressActivation else { return }
            purchaseLimit = nil
            libraries.applyDuress(activation)
            VaultCloudService.shared.stopViewingSessions()
            Task { await VaultCloudService.shared.processDeletions() }
            presentationRevision += 1 // Dismiss sheets, previews, and pickers in every window.
            for id in activation.revokedVaultIDs {
                if lock.revokeAccess(to: id) { Task { await lock.activate() } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VaultEvents.accessRevoked).receive(on: RunLoop.main)) { notification in
            guard let vaultID = notification.object as? String else { return }
            if lock.revokeAccess(to: vaultID) {
                purchaseLimit = nil
                libraries.dismissPresentations()
                Task { await lock.activate() }
            }
        }
    }

    private func beginNewVault(from vault: Vault) {
        Task {
            do {
                try await PatternAuthenticator.shared.checkCanCreateVault()
                guard lock.isActive, lock.unlockedVault?.id == vault.id, !lock.isDummySession else { return }
                libraries.dismissPresentations(); lock.beginNewVault()
            } catch let limit as FreeTierLimit {
                guard lock.isActive, lock.unlockedVault?.id == vault.id, !lock.isDummySession else { return }
                purchaseLimit = limit
            } catch {
                libraries.dismissPresentations(); lock.lock(); await lock.activate()
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
        let view = CapturePrivacyAnchor { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
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
        private weak var contentWindow: UIWindow?
        private var captureRegistration: (any UITraitChangeRegistration)?
        private var cover: UIWindow?
        private var observers: [NSObjectProtocol] = []
        private var activationTask: Task<Void, Never>?
        private var screenshotTask: Task<Void, Never>?
        private var inactive = false
        private var captured = false
        private var screenshotVisible = false
        private var showingCaptureCover = false
        private let screenshotDelay: @MainActor () async throws -> Void

        init(owner: ScenePrivacyShield, screenshotDelay: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: .seconds(2))
        }) {
            self.owner = owner
            self.screenshotDelay = screenshotDelay
        }

        // Avoid the Swift 6.2 implicit isolated-deinit runtime crash.
        deinit {}

        func attach(to window: UIWindow) {
            guard contentWindow !== window else { return }
            if let captureRegistration { contentWindow?.unregisterForTraitChanges(captureRegistration) }
            contentWindow = window
            captureRegistration = window.registerForTraitChanges([UITraitSceneCaptureState.self]) { [weak self] (window: UIWindow, _: UITraitCollection) in
                self?.captureChanged(window.traitCollection.sceneCaptureState == .active)
            }
            captureChanged(window.traitCollection.sceneCaptureState == .active)
        }

        func observe() {
            if let window = anchor?.window { attach(to: window) }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.belongsToScene(notification) else { return }
                    self.activationTask?.cancel()
                    self.inactive = true
                    self.updateCover()
                    self.owner.onInactive()
                }
            })
            observers.append(center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.belongsToScene(notification) else { return }
                    self.activationTask?.cancel()
                    self.inactive = true
                    self.updateCover()
                    self.owner.onBackground()
                }
            })
            observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.belongsToScene(notification) else { return }
                    self.activationTask?.cancel()
                    self.activationTask = Task { [weak self] in
                        guard let self else { return }
                        await self.owner.onActive()
                        // Let the lock view commit its layout before uncovering it.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        self.contentWindow?.layoutIfNeeded()
                        self.inactive = false
                        self.updateCover()
                    }
                }
            })
            observers.append(center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenshotTaken() }
            })
        }

        func captureChanged(_ captured: Bool) {
            self.captured = captured
            if captured { contentWindow?.endEditing(true) }
            updateCover()
        }

        private func screenshotTaken() {
            guard contentWindow != nil else { return }
            // iOS sends this after saving the screenshot. This covers subsequent
            // content briefly; it cannot retroactively blank the saved image.
            screenshotTask?.cancel()
            screenshotVisible = true
            contentWindow?.endEditing(true)
            updateCover()
            screenshotTask = Task { [weak self] in
                guard let self else { return }
                do { try await self.screenshotDelay() } catch { return }
                guard !Task.isCancelled else { return }
                self.screenshotVisible = false
                self.updateCover()
            }
        }

        private func belongsToScene(_ notification: Notification) -> Bool {
            guard let scene = notification.object as? UIWindowScene else { return false }
            return scene === contentWindow?.windowScene
        }

        private func updateCover() {
            let blank = captured || screenshotVisible
            guard inactive || blank else {
                cover?.isHidden = true
                cover = nil
                return
            }
            guard let scene = contentWindow?.windowScene else { return }
            let window = cover ?? UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            if cover == nil || showingCaptureCover != blank {
                window.rootViewController = blank ? BlankCaptureCoverController() : UIHostingController(rootView: PrivacyCover())
                showingCaptureCover = blank
            }
            window.frame = scene.effectiveGeometry.coordinateSpace.bounds
            window.isUserInteractionEnabled = true
            window.accessibilityViewIsModal = true
            window.isHidden = false
            cover = window
        }

        func stop() {
            activationTask?.cancel()
            screenshotTask?.cancel()
            if let captureRegistration { contentWindow?.unregisterForTraitChanges(captureRegistration) }
            captureRegistration = nil
            contentWindow = nil
            anchor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            cover?.isHidden = true
            cover = nil
        }
    }
}

/// Connect to the containing window. Observe its traits, since fullscreen
/// presentations can temporarily detach this root-view anchor from the window.
final class CapturePrivacyAnchor: UIView {
    private let onWindowAttached: @MainActor (UIWindow) -> Void

    init(onWindowAttached: @escaping @MainActor (UIWindow) -> Void) {
        self.onWindowAttached = onWindowAttached
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { onWindowAttached(window) }
    }
}

private final class BlankCaptureCoverController: UIViewController {
    override func loadView() {
        view = UIView()
        view.backgroundColor = .white
        view.isOpaque = true
        view.accessibilityIdentifier = "screenCaptureCover"
    }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            AlbumTheme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                PatternMark(size: 68)
                Text("PatternVault").font(.system(size: 20, weight: .semibold))
            }.foregroundStyle(AlbumTheme.ink)
        }.protectedPreferredColorScheme(.light)
    }
}
