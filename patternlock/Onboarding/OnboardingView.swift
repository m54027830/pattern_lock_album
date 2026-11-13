import SwiftUI
import UIKit

struct OnboardingView: View {
    var onRestored: (() -> Void)?
    // Setup and its completion share the main actor, including stored callbacks.
    let completion: @MainActor (String, [Int], Int, String) async throws -> Void
    @State private var setup: OnboardingStore
    @State private var showingRestore = false
    @State private var showingJoin = false
    @State private var drawing = false
    @State private var phraseShare: OnboardingPhraseShare?
    @State private var operation: Task<Void, Never>?
    @FocusState private var confirmationFocused: Bool

    init(setup: OnboardingStore? = nil, onRestored: (() -> Void)? = nil,
         completion: @escaping @MainActor (String, [Int], Int, String) async throws -> Void) {
        _setup = State(initialValue: setup ?? OnboardingStore())
        self.onRestored = onRestored
        self.completion = completion
    }

    private var chapter: Int {
        switch setup.step {
        case .welcome, .vaultChoice: 0
        case .grid: 1
        case .pattern, .confirm: 2
        case .recovery, .verifyRecovery: 3
        }
    }
    private var title: String {
        switch setup.step {
        case .welcome: [String(localized: "A little space,\njust for you."), String(localized: "A different pattern.\nA different vault."), String(localized: "On your device.\nIn your hands.")][setup.welcomePage]
        case .vaultChoice: String(localized: "Create or restore.")
        case .grid: String(localized: "Find your pattern.")
        case .pattern: String(localized: "Make it yours.")
        case .confirm: String(localized: "Once more.")
        case .recovery: String(localized: "A way back in.")
        case .verifyRecovery: String(localized: "Keep your key safe.")
        }
    }
    private var subtitle: String {
        switch setup.step {
        case .welcome: [String(localized: "Welcome to Pattern. A calm home for the photos and videos you want to keep close."), String(localized: "Each pattern opens its own vault, with separate photos, videos, and folders."), String(localized: "Deleting Pattern removes your local vaults. Enable encrypted iCloud backup in settings to restore after reinstalling.")][setup.welcomePage]
        case .vaultChoice: String(localized: "Choose how you’d like to start.")
        case .grid: String(localized: "Choose the grid you’ll use for every vault. More dots give you more room to draw.")
        case .pattern: String(localized: "Name your first vault, then connect at least 4 different dots.")
        case .confirm: String(localized: "Draw the same pattern again to confirm it.")
        case .recovery: String(localized: "Save a recovery phrase outside Pattern. It can reset this vault’s pattern if you forget it.")
        case .verifyRecovery: String(localized: "Paste or type the phrase you saved, with every word in order.")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: setup.step == .recovery ? 16 : 24) {
                    header
                    if setup.step == .welcome {
                        WelcomeArtwork(page: setup.welcomePage).frame(height: 250).padding(.top, 20)
                    } else if setup.step == .vaultChoice {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(AlbumTheme.accent)
                            .frame(height: 140).accessibilityHidden(true)
                    }
                    VStack(spacing: 12) {
                        Text(title).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-0.8)
                            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboardingTitle")
                        Text(subtitle).font(.subheadline).lineSpacing(4).foregroundStyle(AlbumTheme.secondary)
                    }.multilineTextAlignment(.center).frame(maxWidth: 440)
                    stepContent(width: min(320, geometry.size.width - 64), compact: geometry.size.height < 650)
                    if setup.step != .verifyRecovery { validationMessage }
                    if setup.busy { ProgressView(String(localized: "Preparing your vault…")) }
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 28)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.scrollDisabled(drawing).id(setup.step)
        }
        .background(AlbumTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { footer }
        .foregroundStyle(AlbumTheme.ink).tint(AlbumTheme.accent).preferredColorScheme(.light)
        .disabled(setup.busy)
        .onDisappear { operation?.cancel(); setup.clearSecrets() }
        .sheet(item: $phraseShare) { share in
            OnboardingPhraseShareSheet(phrase: share.phrase) { completed in
                setup.recordPhraseShare(completed: completed, phraseID: share.id)
                phraseShare = nil
            }
        }
        .sheet(isPresented: $showingJoin) {
            NavigationStack {
                JoinSharedVaultView(onJoined: { showingJoin = false; onRestored?() })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { showingJoin = false } } }
            }.tint(AlbumTheme.accent)
        }
        .sheet(isPresented: $showingRestore) {
            NavigationStack {
                RestoreVaultView(onRestored: { showingRestore = false; onRestored?() })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { showingRestore = false } } }
            }.tint(AlbumTheme.accent)
        }
    }

    private var header: some View {
        VStack(spacing: 22) {
            HStack {
                Button { setup.back() } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    .opacity(setup.step == .welcome && setup.welcomePage == 0 ? 0 : 1)
                    .disabled(setup.step == .welcome && setup.welcomePage == 0).accessibilityLabel(String(localized: "Back"))
                Spacer()
                HStack(spacing: 8) { PatternMark(); Text("PATTERN").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(3) }
                Spacer()
                if setup.step == .welcome {
                    Button(String(localized: "Skip"), action: setup.showVaultChoices).font(.caption)
                } else { Color.clear.frame(width: 32, height: 32) }
            }
            HStack(spacing: 6) {
                ForEach(0..<4) { index in
                    Capsule().fill(index <= chapter ? AlbumTheme.accent : AlbumTheme.track).frame(height: 3)
                }
            }.accessibilityLabel(String(localized: "Setup step \(chapter + 1) of 4"))
        }
    }

    @ViewBuilder private func stepContent(width: CGFloat, compact: Bool) -> some View {
        switch setup.step {
        case .welcome:
            HStack(spacing: 7) {
                ForEach(0..<3) { index in
                    Capsule().fill(index == setup.welcomePage ? AlbumTheme.accent : AlbumTheme.track)
                        .frame(width: index == setup.welcomePage ? 24 : 6, height: 6)
                }
            }.padding(.top, 12).accessibilityLabel(String(localized: "Welcome page \(setup.welcomePage + 1) of 3"))
            Label([String(localized: "No account needed"), String(localized: "One pattern for each vault"), String(localized: "Your recovery phrase stays yours")][setup.welcomePage], systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(AlbumTheme.secondary)
            if setup.welcomePage == 2 {
                Text(String(localized: "Start free: 3 albums · 5 photos/videos each.\nRemove both limits with one purchase in settings."))
                    .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
            }
        case .vaultChoice:
            VStack(spacing: 14) {
                vaultChoice(String(localized: "Create a new vault"),
                            detail: String(localized: "Choose a pattern and get a new recovery phrase."),
                            icon: "plus", action: setup.startSetup)
                    .accessibilityIdentifier("onboardingCreateVault")
                if onRestored != nil {
                    vaultChoice(String(localized: "Restore an existing vault"),
                                detail: String(localized: "Use an iCloud backup and its recovery phrase."),
                                icon: "icloud.and.arrow.down") { showingRestore = true }
                        .accessibilityIdentifier("onboardingRestoreVault")
                    vaultChoice(String(localized: "Join shared vault"), detail: String(localized: "Enter a sharing phrase from someone you trust."), icon: "person.badge.plus") { showingJoin = true }
                        .accessibilityIdentifier("onboardingJoinSharedVault")
                }
            }
        case .grid:
            if !compact {
                GridIllustration(size: setup.gridSize).frame(width: 180, height: 180).padding(20)
                    .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 32))
            }
            GridSizePicker(selection: $setup.gridSize)
            Text(String(localized: "You can change this in settings. Changing the grid means creating new patterns for all your vaults."))
                .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
        case .pattern, .confirm:
            if setup.step == .pattern {
                TextField(String(localized: "First vault name"), text: $setup.vaultName)
                    .textInputAutocapitalization(.words).submitLabel(.done)
                    .padding(16).vaultMetalSurface(in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("firstVaultName")
            } else { Text(setup.vaultName).font(.subheadline.weight(.medium)).foregroundStyle(AlbumTheme.accent) }
            PatternGridView(side: width, gridSize: setup.gridSize, isEnabled: !setup.busy, revision: setup.revision, isDrawing: $drawing, completed: setup.submit)
            Text(String(localized: "Lift your finger when you’re done.")).font(.caption).foregroundStyle(AlbumTheme.secondary)
        case .recovery:
            Picker(String(localized: "Phrase type"), selection: $setup.useCustomPhrase) {
                Text(String(localized: "Generated")).tag(false)
                Text(String(localized: "Custom phrase")).tag(true)
            }.pickerStyle(.segmented)
            if setup.useCustomPhrase {
                SecureField(String(localized: "At least 8 words and 40 characters"), text: $setup.customPhrase)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .padding(18).vaultMetalSurface(in: RoundedRectangle(cornerRadius: 18))
                Text(setup.canSavePhrase
                     ? String(localized: "Choose unrelated, unpredictable words. A generated phrase is recommended.")
                     : String(localized: "Use at least 8 words and 40 characters, up to 1,024 characters. A generated phrase is recommended."))
                    .font(.caption).foregroundStyle(AlbumTheme.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(Array(setup.generatedPhrase.split(separator: " ").enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1)).foregroundStyle(AlbumTheme.secondary).font(.caption.monospacedDigit())
                            Text(String(word)).font(.system(.subheadline, design: .monospaced))
                        }
                    }
                }.padding(20).vaultMetalSurface(in: RoundedRectangle(cornerRadius: 22)).privacySensitive()
            }
            VStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { sharePhraseButton; copyPhraseButton }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 8) { sharePhraseButton; copyPhraseButton }
                }
                .disabled(!setup.canSavePhrase)
                Text(String(localized: "Tap Save to Notes, choose Notes, then save. Or copy the phrase into a password manager. You’ll need it on the next screen."))
                    .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
                if setup.sharedPhrase {
                    Label(String(localized: "Phrase shared"), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(AlbumTheme.accent)
                }
            }
        case .verifyRecovery:
            Image(systemName: "key.horizontal").font(.system(size: 50, weight: .ultraLight)).foregroundStyle(AlbumTheme.accent).padding(20)
            SecureField(String(localized: "Repeat the whole recovery phrase"), text: $setup.confirmation)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                .focused($confirmationFocused)
                .padding(18).vaultMetalSurface(in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("onboardingPhraseConfirmation")
            validationMessage
            Toggle(String(localized: "I saved my phrase outside Pattern"), isOn: $setup.savedPhrase).font(.subheadline)
            Text(String(localized: "The phrase won’t be shown again after setup. Keep it to reset a forgotten pattern or open an iCloud backup. A phrase alone cannot restore photos after deleting the app."))
                .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
        }
    }

    private var sharePhraseButton: some View {
        Button(String(localized: "Save to Notes"), systemImage: "square.and.arrow.up") {
            phraseShare = OnboardingPhraseShare(id: setup.phraseID, phrase: setup.phrase)
        }
        .font(.subheadline).buttonStyle(.bordered).controlSize(.large)
        .accessibilityIdentifier("onboardingSharePhrase")
    }

    private var copyPhraseButton: some View {
        Button(setup.copiedPhrase ? String(localized: "Copied") : String(localized: "Copy phrase"), systemImage: setup.copiedPhrase ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: setup.phrase]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
            setup.markPhraseCopied()
        }
        .frame(minHeight: 44).font(.subheadline)
        .accessibilityIdentifier("onboardingCopyPhrase")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            switch setup.step {
            case .welcome:
                primary(String(localized: "Continue")) {
                    if setup.welcomePage < 2 { withAnimation(.easeInOut(duration: 0.2)) { setup.welcomePage += 1 } }
                    else { setup.showVaultChoices() }
                }
                if onRestored != nil {
                    Button(String(localized: "Restore from iCloud")) { showingRestore = true }.font(.caption).padding(.top, 4)
                }
            case .vaultChoice: EmptyView()
            case .grid: primary(String(localized: "Use \(setup.gridSize) × \(setup.gridSize) grid"), action: setup.chooseGrid)
            case .pattern: EmptyView()
            case .confirm: Button(String(localized: "Draw a different pattern"), action: setup.back).font(.subheadline).padding(10)
            case .recovery:
                if !setup.canContinueRecovery {
                    Text(String(localized: "Copy or share your phrase before continuing."))
                        .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
                }
                primary(String(localized: "I’ve saved my phrase"), action: setup.confirmRecovery)
                    .disabled(!setup.canContinueRecovery).opacity(setup.canContinueRecovery ? 1 : 0.45)
            case .verifyRecovery:
                primary(String(localized: "Confirm my phrase")) {
                    confirmationFocused = false
                    operation = Task { await setup.finish(completion) }
                }
            }
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
            .frame(maxWidth: 560).frame(maxWidth: .infinity).background(AlbumTheme.background)
    }

    @ViewBuilder private var validationMessage: some View {
        if let error = setup.error {
            VStack(spacing: 12) {
                Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                if setup.recoveryConfirmationMismatch {
                    Button(String(localized: "Show my phrase"), action: setup.back)
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("onboardingShowPhrase")
                }
            }
            .accessibilityIdentifier("onboardingError")
        }
    }

    private func vaultChoice(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 24, weight: .light))
                    .frame(width: 48, height: 48)
                    .background(AlbumTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(AlbumTheme.ink)
                    Text(detail).font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .multilineTextAlignment(.leading).padding(20)
            .foregroundStyle(AlbumTheme.accent)
            .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Image(systemName: "arrow.right") }
                .font(.subheadline.weight(.semibold)).padding(20).foregroundStyle(.white)
                .vaultPrimarySurface(in: RoundedRectangle(cornerRadius: 20))
        }.accessibilityIdentifier("onboardingContinue")
    }
}

private struct OnboardingPhraseShare: Identifiable {
    let id: UUID
    let phrase: String
}

struct OnboardingPhraseShareSheet: UIViewControllerRepresentable {
    let phrase: String
    let completion: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [phrase], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            let succeeded = completed && error == nil
            Task { @MainActor in completion(succeeded) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct GridSizePicker: View {
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 12) {
            ForEach(PatternRules.supportedSizes, id: \.self) { size in
                Button { selection = size } label: {
                    VStack(spacing: 14) {
                        GridIllustration(size: size).frame(width: 46, height: 46)
                        Text(String(localized: "\(size) × \(size)")).font(.subheadline.weight(.semibold))
                        Image(systemName: selection == size ? "checkmark.circle.fill" : "circle").font(.body)
                    }.frame(maxWidth: .infinity).padding(.vertical, 18)
                        .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 18), tint: selection == size ? AlbumTheme.selectedSurface : AlbumTheme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selection == size ? AlbumTheme.accent : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain).foregroundStyle(AlbumTheme.accent)
                    .accessibilityLabel(String(localized: "\(size) by \(size)")).accessibilityAddTraits(selection == size ? .isSelected : [])
                    .accessibilityIdentifier("gridSize\(size)")
            }
        }
    }
}

struct GridIllustration: View {
    let size: Int
    var connected = false
    var body: some View {
        Canvas { context, bounds in
            let geometry = PatternGridGeometry(side: min(bounds.width, bounds.height), gridSize: size)
            if connected {
                let nodes = [0, size + 1, 2 * size + 2, 2 * size + 1]
                var path = Path(); path.move(to: geometry.center(nodes[0]))
                for node in nodes.dropFirst() { path.addLine(to: geometry.center(node)) }
                context.stroke(path, with: .color(AlbumTheme.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            for node in 0..<(size * size) {
                let point = geometry.center(node), radius = bounds.width > 100 ? 5.0 : 2.4
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(AlbumTheme.accent.opacity(0.65)))
            }
        }.accessibilityHidden(true)
    }
}

private struct WelcomeArtwork: View {
    let page: Int
    var body: some View {
        ZStack {
            Circle().fill(AlbumTheme.accent.opacity(0.06)).frame(width: 235, height: 235)
            if page == 1 {
                GridIllustration(size: 4, connected: true).frame(width: 175, height: 175)
                Label(String(localized: "A space of its own"), systemImage: "lock.open")
                    .font(.caption.weight(.medium)).padding(12).vaultMetalSurface(in: Capsule()).offset(y: 108)
            } else {
                RoundedRectangle(cornerRadius: 24).fill(AlbumTheme.folderColor(1).gradient).frame(width: 156, height: 184).rotationEffect(.degrees(-13)).offset(x: -25, y: -8)
                VStack(spacing: 18) {
                    Image(systemName: page == 0 ? "photo.on.rectangle.angled" : "icloud.and.arrow.up")
                        .font(.system(size: 52, weight: .ultraLight))
                    Text(page == 0 ? String(localized: "Your moments") : String(localized: "Your choice")).font(.caption.weight(.medium))
                }.foregroundStyle(AlbumTheme.accent).frame(width: 160, height: 190)
                    .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 24), tint: AlbumTheme.folderColor(0))
                    .rotationEffect(.degrees(8)).offset(x: 25, y: 8)
                Image(systemName: page == 0 ? "lock.fill" : "key.fill").font(.title3)
                    .foregroundStyle(.white).frame(width: 52, height: 52).vaultPrimarySurface(in: Circle()).offset(x: 98, y: 92)
            }
        }.accessibilityHidden(true)
    }
}
