import SwiftUI

struct PatternLockView: View {
    @Bindable var lock: PatternLockStore
    @State private var isDrawing = false
    @State private var showingRecovery = false
    @State private var showingRestore = false
    @FocusState private var nameFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var title: String {
        switch lock.stage {
        case .nameVault: "A space of its own."
        case .create: lock.isCreatingVault ? "A new pattern." : "Make it yours."
        case .confirm: "Once more."
        case .locked: "Welcome back."
        case .faceID: "One more step."
        case .unavailable: "Your library is locked."
        default: "Your space, protected."
        }
    }

    private var subtitle: String {
        switch lock.stage {
        case .nameVault: "Give your new vault a name.\nIts photos and folders stay separate."
        case .create: lock.isCreatingVault ? "Choose a unique pattern for \(lock.vaultName).\nConnect at least 4 dots." : "Draw a pattern to lock your library.\nConnect at least 4 dots."
        case .confirm: "Draw the same pattern again\nto make sure you remember it."
        case .locked: "Draw a pattern to open its vault."
        case .faceID: "Use Face ID to open your vault."
        case .unavailable: "We couldn’t access your saved pattern."
        default: "Getting your lock ready…"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        PatternMark().frame(width: 25, height: 25)
                        Text("PATTERN").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(3)
                    }
                    .foregroundStyle(AlbumTheme.ink)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if lock.isCreatingVault {
                            Button("Cancel") { nameFocused = false; lock.cancelNewVault() }
                                .font(.subheadline).padding(.leading, 24).disabled(lock.isBusy)
                                .accessibilityIdentifier("cancelNewVault")
                        }
                    }
                    .padding(.top, 25).padding(.bottom, 35)

                    Image(systemName: lock.stage == .faceID ? "faceid" : lock.stage == .confirm ? "checkmark.shield" : "lock")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(AlbumTheme.accent)
                        .frame(width: 62, height: 62)
                        .background(AlbumTheme.accent.opacity(0.07), in: Circle())
                        .padding(.bottom, 21)
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.system(size: 33, weight: .semibold, design: .rounded))
                        .tracking(-0.8).foregroundStyle(AlbumTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("patternLockTitle")
                    Text(subtitle)
                        .font(.subheadline).lineSpacing(5)
                        .foregroundStyle(AlbumTheme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 46).padding(.top, 12)

                    if lock.stage == .create || lock.stage == .confirm {
                        HStack(spacing: 8) {
                            step("1", title: "Create", active: lock.stage == .create, complete: lock.stage == .confirm)
                            Rectangle().fill(AlbumTheme.track).frame(width: 20, height: 1)
                            step("2", title: "Confirm", active: lock.stage == .confirm, complete: false)
                        }.padding(.top, 25)
                    }

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil((lock.retryAfter ?? .distantPast).timeIntervalSince(context.date))))
                        VStack(spacing: 15) {
                            if [.create, .confirm, .locked].contains(lock.stage) {
                                PatternGridView(
                                    side: min(340, geometry.size.width - 50),
                                    isEnabled: lock.isActive && !lock.isBusy && remaining == 0,
                                    revision: lock.inputRevision,
                                    isDrawing: $isDrawing
                                ) { nodes in Task { await lock.submit(nodes) } }
                                .padding(.top, lock.stage == .locked ? 30 : 20)
                            } else if lock.stage == .nameVault {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("Vault name").font(.subheadline.weight(.semibold)).foregroundStyle(AlbumTheme.ink)
                                    TextField("e.g. Travel, Family, Personal", text: $lock.vaultName)
                                        .focused($nameFocused)
                                        .textInputAutocapitalization(.words)
                                        .submitLabel(.continue)
                                        .padding(17).background(.white, in: RoundedRectangle(cornerRadius: 15))
                                        .onSubmit { nameFocused = false; lock.continueWithVaultName() }
                                        .accessibilityIdentifier("newVaultName")
                                    Button {
                                        nameFocused = false
                                        lock.continueWithVaultName()
                                    } label: {
                                        HStack { Text("Choose pattern"); Image(systemName: "arrow.right") }
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity).padding(17)
                                            .foregroundStyle(.white).background(AlbumTheme.accent, in: Capsule())
                                    }
                                    .disabled(lock.vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .accessibilityIdentifier("chooseVaultPattern")
                                }.frame(maxWidth: 340).padding(.horizontal, 25).padding(.vertical, 35)
                            } else {
                                VStack(spacing: 20) {
                                    if lock.stage == .unavailable {
                                        Image(systemName: "lock.trianglebadge.exclamation").font(.system(size: 42, weight: .light))
                                        Button("Try again") { Task { await lock.activate() } }
                                            .font(.subheadline.weight(.semibold)).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                    } else { ProgressView().tint(AlbumTheme.accent) }
                                }.frame(height: 220)
                            }
                            status(remaining: remaining)
                                .frame(minHeight: 52)
                                .padding(.horizontal, 28)
                        }
                    }

                    if lock.stage == .confirm {
                        Button("Choose a different pattern") { lock.startOver() }
                            .font(.subheadline.weight(.medium)).padding(.vertical, 15)
                            .disabled(lock.isBusy).accessibilityIdentifier("restartPatternSetup")
                    } else if lock.stage == .create && lock.isCreatingVault {
                        Button("Edit vault name") { lock.editVaultName() }
                            .font(.subheadline.weight(.medium)).padding(.vertical, 15)
                    } else {
                        Text(lock.stage == .create ? "Choose a pattern you’ll remember." : "A little space that’s only yours.")
                            .font(.caption).foregroundStyle(AlbumTheme.secondary.opacity(0.8))
                            .padding(.vertical, 18)
                    }
                    Spacer(minLength: 20)
                    if !lock.isCreatingVault && [.locked, .create, .unavailable].contains(lock.stage) {
                        HStack(spacing: 24) {
                            if lock.stage != .create {
                                Button("Recover vault") { showingRecovery = true }
                            }
                            Button("Restore from iCloud") { showingRestore = true }
                        }.font(.caption).padding(.bottom, 20).disabled(lock.isBusy)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(isDrawing)
        }
        .background(AlbumTheme.background.ignoresSafeArea())
        .tint(AlbumTheme.accent)
        .preferredColorScheme(.light)
        .sensoryFeedback(.error, trigger: lock.failureRevision)
        .sheet(item: $lock.purchaseLimit) { PurchaseView(reason: $0) }
        .sheet(isPresented: $showingRecovery) {
            NavigationStack {
                RecoverPatternView { showingRecovery = false; lock.lock(); Task { await lock.activate() } }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingRecovery = false } } }
            }.tint(AlbumTheme.accent)
        }
        .sheet(isPresented: $showingRestore) {
            NavigationStack {
                RestoreVaultView(onRestored: { showingRestore = false; lock.lock(); Task { await lock.activate() } })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingRestore = false } } }
            }.tint(AlbumTheme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { showingRecovery = false; showingRestore = false }
        }
    }

    private func step(_ number: String, title: String, active: Bool, complete: Bool) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(active || complete ? AlbumTheme.accent : AlbumTheme.track).frame(width: 21, height: 21)
                if complete { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                else { Text(number).font(.system(size: 10, weight: .semibold)).foregroundStyle(active ? .white : AlbumTheme.secondary) }
            }
            Text(title).font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active || complete ? AlbumTheme.accent : AlbumTheme.secondary)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private func status(remaining: Int) -> some View {
        if lock.isBusy {
            HStack(spacing: 9) { ProgressView(); Text(lock.stage == .faceID ? "Waiting for Face ID…" : lock.stage == .confirm ? "Saving your pattern…" : "Checking your pattern…").font(.caption) }
                .foregroundStyle(AlbumTheme.secondary)
        } else if remaining > 0 {
            VStack(spacing: 5) {
                Text("Too many attempts").font(.subheadline.weight(.medium))
                Text("Try again in \(remaining)s").font(.caption.monospacedDigit())
            }.foregroundStyle(AlbumTheme.secondary)
        } else if let message = lock.message {
            Text(message).font(.subheadline).multilineTextAlignment(.center)
                .foregroundStyle(.red.opacity(0.85)).accessibilityIdentifier("patternError")
        } else if lock.stage == .nameVault {
            Text("Next, create and confirm its pattern.")
                .font(.caption).foregroundStyle(AlbumTheme.secondary)
        } else {
            Text("Lift your finger when you’re done.")
                .font(.caption).foregroundStyle(AlbumTheme.secondary)
        }
    }
}

private struct PatternGridSizeKey: EnvironmentKey { static let defaultValue = 5 }

extension EnvironmentValues {
    var patternGridSize: Int {
        get { self[PatternGridSizeKey.self] }
        set { self[PatternGridSizeKey.self] = newValue }
    }
}

struct PatternGridView: View {
    let side: CGFloat
    var gridSize: Int? = nil
    @Environment(\.patternGridSize) private var inheritedGridSize
    private var size: Int { gridSize ?? inheritedGridSize }
    let isEnabled: Bool
    let revision: Int
    @Binding var isDrawing: Bool
    let completed: ([Int]) -> Void
    @State private var path = PatternPath()
    @State private var finger: CGPoint?
    @State private var previousPoint: CGPoint?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private var geometry: PatternGridGeometry { PatternGridGeometry(side: side, gridSize: size) }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Path { line in
                    guard let first = path.nodes.first else { return }
                    line.move(to: geometry.center(first))
                    for node in path.nodes.dropFirst() { line.addLine(to: geometry.center(node)) }
                    if let finger { line.addLine(to: finger) }
                }
                .stroke(AlbumTheme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                ForEach(0..<(size * size), id: \.self) { node in
                    let selected = path.nodes.contains(node)
                    ZStack {
                        Circle().fill(selected ? AlbumTheme.accent.opacity(0.10) : .clear).frame(width: 33, height: 33)
                        Circle().strokeBorder(selected ? AlbumTheme.accent.opacity(0.23) : .clear, lineWidth: 1).frame(width: 33, height: 33)
                        Circle().fill(selected ? AlbumTheme.accent : AlbumTheme.ink.opacity(0.25))
                            .frame(width: selected ? 12 : 9, height: selected ? 12 : 9)
                    }.position(geometry.center(node))
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard isEnabled else { return }
                    isDrawing = true
                    for node in geometry.crossedNodes(from: previousPoint ?? value.startLocation, to: value.location) { path.append(node) }
                    previousPoint = value.location
                    finger = value.location
                }
                .onEnded { value in
                    guard isEnabled else { clear(); return }
                    for node in geometry.crossedNodes(from: previousPoint ?? value.startLocation, to: value.location) { path.append(node) }
                    finish()
                })
            .accessibilityRepresentation {
                VStack {
                    ForEach(0..<size, id: \.self) { row in
                        HStack {
                            ForEach(0..<size, id: \.self) { column in
                                let node = row * size + column
                                Button("Row \(row + 1), column \(column + 1)") {
                                    guard isEnabled else { return }
                                    path.append(node)
                                }
                                .accessibilityValue(path.nodes.contains(node) ? "Selected" : "Not selected")
                                .accessibilityIdentifier("patternDot\(node)")
                                .disabled(!isEnabled || path.nodes.contains(node))
                            }
                        }
                    }
                }.accessibilityLabel("\(size) by \(size) pattern grid")
            }
            if voiceOver {
                HStack(spacing: 30) {
                    Button("Clear pattern") { clear() }
                    Button("Use pattern") { finish() }.disabled(path.nodes.isEmpty)
                }.font(.subheadline).disabled(!isEnabled)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .sensoryFeedback(.selection, trigger: path.nodes.count)
        .onChange(of: revision) { _, _ in clear() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { clear() } }
        .onChange(of: side) { _, _ in clear() }
        .onChange(of: size) { _, _ in clear() }
        .onAppear { clear() }
        .onDisappear { clear() }
        .accessibilityIdentifier("patternGrid")
    }

    private func finish() {
        let nodes = path.nodes
        clear()
        guard !nodes.isEmpty else { return }
        completed(nodes)
    }
    private func clear() {
        path = PatternPath(gridSize: size)
        finger = nil
        previousPoint = nil
        isDrawing = false
    }
}
