import SwiftUI
import UIKit

struct OnboardingView: View {
    var onRestored: (() -> Void)?
    let completion: (String, [Int], Int, String) async throws -> Void
    @State private var setup: OnboardingStore
    @State private var showingRestore = false
    @State private var drawing = false
    @State private var copied = false
    @State private var operation: Task<Void, Never>?

    init(setup: OnboardingStore? = nil, onRestored: (() -> Void)? = nil,
         completion: @escaping (String, [Int], Int, String) async throws -> Void) {
        _setup = State(initialValue: setup ?? OnboardingStore())
        self.onRestored = onRestored
        self.completion = completion
    }

    private var chapter: Int {
        switch setup.step {
        case .welcome: 0
        case .grid: 1
        case .pattern, .confirm: 2
        case .recovery, .verifyRecovery: 3
        }
    }
    private var title: String {
        switch setup.step {
        case .welcome: ["A little space,\njust for you.", "A different pattern.\nA different vault.", "On your device.\nIn your hands."][setup.welcomePage]
        case .grid: "Find your pattern."
        case .pattern: "Make it yours."
        case .confirm: "Once more."
        case .recovery: "A way back in."
        case .verifyRecovery: "Keep your key safe."
        }
    }
    private var subtitle: String {
        switch setup.step {
        case .welcome: ["Welcome to Pattern. A calm home for the photos and videos you want to keep close.", "Each pattern opens its own vault, with separate photos, videos, and folders.", "Keep your media locally. When you’re ready, save an encrypted backup to iCloud Drive from settings."][setup.welcomePage]
        case .grid: "Choose the grid you’ll use for every vault. More dots give you more room to draw."
        case .pattern: "Name your first vault, then connect at least 4 different dots."
        case .confirm: "Draw the same pattern again to confirm it."
        case .recovery: "Save a recovery phrase outside Pattern. It can reset this vault’s pattern if you forget it."
        case .verifyRecovery: "Repeat your saved phrase to make sure you can recover your vault."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if setup.step == .welcome {
                        WelcomeArtwork(page: setup.welcomePage).frame(height: 250).padding(.top, 20)
                    }
                    VStack(spacing: 12) {
                        Text(title).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-0.8)
                            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboardingTitle")
                        Text(subtitle).font(.subheadline).lineSpacing(4).foregroundStyle(AlbumTheme.secondary)
                    }.multilineTextAlignment(.center).frame(maxWidth: 440)
                    stepContent(width: min(320, geometry.size.width - 64), compact: geometry.size.height < 650)
                    if let error = setup.error { Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center) }
                    if setup.busy { ProgressView("Preparing your vault…") }
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 28)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.scrollDisabled(drawing)
        }
        .background(AlbumTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { footer }
        .foregroundStyle(AlbumTheme.ink).tint(AlbumTheme.accent).preferredColorScheme(.light)
        .disabled(setup.busy)
        .onDisappear { operation?.cancel(); setup.clearSecrets() }
        .sheet(isPresented: $showingRestore) {
            NavigationStack {
                RestoreVaultView(onRestored: { showingRestore = false; onRestored?() })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingRestore = false } } }
            }.tint(AlbumTheme.accent)
        }
    }

    private var header: some View {
        VStack(spacing: 22) {
            HStack {
                Button { setup.back() } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    .opacity(setup.step == .welcome && setup.welcomePage == 0 ? 0 : 1)
                    .disabled(setup.step == .welcome && setup.welcomePage == 0).accessibilityLabel("Back")
                Spacer()
                HStack(spacing: 8) { PatternMark(); Text("PATTERN").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(3) }
                Spacer()
                if setup.step == .welcome {
                    Button("Skip") { setup.startSetup() }.font(.caption)
                } else { Color.clear.frame(width: 32, height: 32) }
            }
            HStack(spacing: 6) {
                ForEach(0..<4) { index in
                    Capsule().fill(index <= chapter ? AlbumTheme.accent : AlbumTheme.track).frame(height: 3)
                }
            }.accessibilityLabel("Setup step \(chapter + 1) of 4")
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
            }.padding(.top, 12).accessibilityLabel("Welcome page \(setup.welcomePage + 1) of 3")
            Label(["No account needed", "One pattern for each vault", "Your recovery phrase stays yours"][setup.welcomePage], systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(AlbumTheme.secondary)
            if setup.welcomePage == 2 {
                Text("Start free: 3 albums · 5 photos/videos each.\nRemove both limits with one purchase in settings.")
                    .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
            }
        case .grid:
            if !compact {
                GridIllustration(size: setup.gridSize).frame(width: 180, height: 180).padding(20)
                    .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 32))
            }
            GridSizePicker(selection: $setup.gridSize)
            Text("You can change this in settings. Changing the grid means creating new patterns for all your vaults.")
                .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
        case .pattern, .confirm:
            if setup.step == .pattern {
                TextField("First vault name", text: $setup.vaultName)
                    .textInputAutocapitalization(.words).submitLabel(.done)
                    .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("firstVaultName")
            } else { Text(setup.vaultName).font(.subheadline.weight(.medium)).foregroundStyle(AlbumTheme.accent) }
            PatternGridView(side: width, gridSize: setup.gridSize, isEnabled: !setup.busy, revision: setup.revision, isDrawing: $drawing, completed: setup.submit)
            Text("Lift your finger when you’re done.").font(.caption).foregroundStyle(AlbumTheme.secondary)
        case .recovery:
            Picker("Phrase type", selection: $setup.useCustomPhrase) {
                Text("Generated").tag(false)
                Text("Custom phrase").tag(true)
            }.pickerStyle(.segmented)
            if setup.useCustomPhrase {
                SecureField("At least 8 words and 40 characters", text: $setup.customPhrase)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 18))
                Text("Choose unrelated, unpredictable words. A generated phrase is recommended.")
                    .font(.caption).foregroundStyle(AlbumTheme.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(Array(setup.generatedPhrase.split(separator: " ").enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1)).foregroundStyle(AlbumTheme.secondary).font(.caption.monospacedDigit())
                            Text(String(word)).font(.system(.subheadline, design: .monospaced))
                        }
                    }
                }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 22)).privacySensitive()
                Button(copied ? "Copied" : "Copy phrase", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: setup.phrase]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
                    copied = true
                }.font(.subheadline)
            }
            Label("Write it down. Keep it safe. Keep it private.", systemImage: "key")
                .font(.caption).foregroundStyle(AlbumTheme.secondary)
        case .verifyRecovery:
            Image(systemName: "key.horizontal").font(.system(size: 50, weight: .ultraLight)).foregroundStyle(AlbumTheme.accent).padding(20)
            SecureField("Repeat the whole recovery phrase", text: $setup.confirmation)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("onboardingPhraseConfirmation")
            Toggle("I saved my phrase outside Pattern", isOn: $setup.savedPhrase).font(.subheadline)
            Text("The phrase won’t be shown again after setup. Anyone with it can reset this vault’s pattern and open backups made with it.")
                .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            switch setup.step {
            case .welcome:
                primary(setup.welcomePage == 2 ? "Set up my vault" : "Continue") {
                    if setup.welcomePage < 2 { withAnimation(.easeInOut(duration: 0.2)) { setup.welcomePage += 1 } }
                    else { setup.startSetup() }
                }
                if onRestored != nil {
                    Button("Restore an existing backup") { showingRestore = true }.font(.caption).padding(.top, 4)
                }
            case .grid: primary("Use \(setup.gridSize) × \(setup.gridSize) grid", action: setup.chooseGrid)
            case .pattern: EmptyView()
            case .confirm: Button("Draw a different pattern", action: setup.back).font(.subheadline).padding(10)
            case .recovery: primary("I’ve saved my phrase", action: setup.confirmRecovery)
            case .verifyRecovery:
                primary("Open my vault") { operation = Task { await setup.finish(completion) } }
                    .disabled(!setup.canFinish).opacity(setup.canFinish ? 1 : 0.45)
            }
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
            .frame(maxWidth: 560).frame(maxWidth: .infinity).background(AlbumTheme.background)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Image(systemName: "arrow.right") }
                .font(.subheadline.weight(.semibold)).padding(20).foregroundStyle(.white)
                .background(AlbumTheme.accent, in: RoundedRectangle(cornerRadius: 20))
        }.accessibilityIdentifier("onboardingContinue")
    }
}

struct GridSizePicker: View {
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 12) {
            ForEach(PatternRules.supportedSizes, id: \.self) { size in
                Button { selection = size } label: {
                    VStack(spacing: 14) {
                        GridIllustration(size: size).frame(width: 46, height: 46)
                        Text("\(size) × \(size)").font(.subheadline.weight(.semibold))
                        Image(systemName: selection == size ? "checkmark.circle.fill" : "circle").font(.body)
                    }.frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(selection == size ? AlbumTheme.accent.opacity(0.09) : .white, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selection == size ? AlbumTheme.accent : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain).foregroundStyle(AlbumTheme.accent)
                    .accessibilityLabel("\(size) by \(size)").accessibilityAddTraits(selection == size ? .isSelected : [])
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
                Label("A space of its own", systemImage: "lock.open")
                    .font(.caption.weight(.medium)).padding(12).background(.white, in: Capsule()).offset(y: 108)
            } else {
                RoundedRectangle(cornerRadius: 24).fill(AlbumTheme.folderColor(1)).frame(width: 156, height: 184).rotationEffect(.degrees(-13)).offset(x: -25, y: -8)
                VStack(spacing: 18) {
                    Image(systemName: page == 0 ? "photo.on.rectangle.angled" : "icloud.and.arrow.up")
                        .font(.system(size: 52, weight: .ultraLight))
                    Text(page == 0 ? "Your moments" : "Your choice").font(.caption.weight(.medium))
                }.foregroundStyle(AlbumTheme.accent).frame(width: 160, height: 190)
                    .background(AlbumTheme.folderColor(0), in: RoundedRectangle(cornerRadius: 24))
                    .rotationEffect(.degrees(8)).offset(x: 25, y: 8)
                Image(systemName: page == 0 ? "lock.fill" : "key.fill").font(.title3)
                    .foregroundStyle(.white).frame(width: 52, height: 52).background(AlbumTheme.accent, in: Circle()).offset(x: 98, y: 92)
            }
        }.accessibilityHidden(true)
    }
}
