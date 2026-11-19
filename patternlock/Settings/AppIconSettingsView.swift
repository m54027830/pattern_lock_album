import SwiftUI

struct AppIconSettingsView: View {
    @Bindable var icons: AppIconStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(String(localized: "Choose a look for PatternVault. This changes the app icon on this device for all vaults."))
                    .font(.subheadline).foregroundStyle(AlbumTheme.secondary)

                Button { choose(.classic) } label: {
                    HStack(spacing: 16) {
                        AppIconPreview(icon: .classic, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppIcon.classic.title).font(.headline)
                            Text(String(localized: "Original icon")).font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                        }
                        Spacer()
                        indicator(for: .classic)
                    }
                    .padding(16)
                    .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .disabled(!icons.supportsAlternateIcons)
                .accessibilityAddTraits(icons.selected == .classic ? [.isSelected] : [])
                .accessibilityIdentifier("appIcon-Classic")

                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "Utility icons")).font(.headline)
                    iconGrid(AppIcon.utilityIcons)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "Pattern icons")).font(.headline)
                    iconGrid(AppIcon.patternIcons)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Home Screen name")).font(.headline)
                    Text(String(localized: "iOS keeps the app’s name as PatternVault when you change its icon. A shortcut can use a different name and matching artwork."))
                        .font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                    NavigationLink {
                        AppIconShortcutGuide(icon: icons.selected)
                    } label: {
                        Label(String(localized: "Set up a named shortcut"), systemImage: "arrow.up.forward.app")
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                }
                if !icons.supportsAlternateIcons {
                    Text(String(localized: "App icon changes aren’t available on this device."))
                        .font(.footnote).foregroundStyle(AlbumTheme.secondary)
                }
            }
            .foregroundStyle(AlbumTheme.ink)
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .disabled(icons.isChanging)
        }
        .background(AlbumTheme.background)
        .navigationTitle(String(localized: "App icon"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { icons.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { icons.refresh() } }
        .alert(String(localized: "Couldn’t change app icon"), isPresented: Binding(get: { icons.errorMessage != nil }, set: { if !$0 { icons.dismissError() } })) {
            Button(String(localized: "OK"), role: .cancel) { icons.dismissError() }
        } message: { Text(icons.errorMessage ?? "") }
    }

    private func iconGrid(_ choices: [AppIcon]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12)], spacing: 16) {
            ForEach(choices) { icon in
                Button { choose(icon) } label: {
                    VStack(spacing: 10) {
                        AppIconPreview(icon: icon, size: 76)
                            .overlay(alignment: .bottomTrailing) {
                                indicator(for: icon).offset(x: 7, y: 7)
                            }
                        Text(icon.title)
                            .font(.caption.weight(.medium))
                            .multilineTextAlignment(.center)
                            .frame(minHeight: 30, alignment: .top)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14).padding(.bottom, 6)
                    .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 20), tint: icons.selected == icon ? AlbumTheme.selectedSurface : AlbumTheme.surface)
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(icons.selected == icon ? AlbumTheme.accent : .clear, lineWidth: 2) }
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon.title)
                .accessibilityAddTraits(icons.selected == icon ? [.isSelected] : [])
                .accessibilityIdentifier("appIcon-" + icon.rawValue)
            }
        }
        .disabled(!icons.supportsAlternateIcons)
    }

    @ViewBuilder private func indicator(for icon: AppIcon) -> some View {
        if icons.pending == icon {
            ProgressView().tint(AlbumTheme.accent)
                .frame(width: 26, height: 26).background(.white, in: Circle())
                .accessibilityLabel(String(localized: "Changing app icon…"))
        } else if icons.selected == icon {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(AlbumTheme.accent, .white)
                .accessibilityHidden(true)
        }
    }

    private func choose(_ icon: AppIcon) {
        Task { await icons.select(icon) }
    }
}

private struct AppIconShortcutGuide: View {
    let icon: AppIcon

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    AppIconPreview(icon: icon, size: 88)
                    Text(icon.shortcutName).font(.headline)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                ShareLink(item: Image(icon.previewAsset), preview: SharePreview(icon.shortcutName, image: Image(icon.previewAsset))) {
                    Label(String(localized: "Export icon"), systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text(String(localized: "Save the icon to Files using the share sheet."))
            }
            Section {
                Text(String(localized: "Open Shortcuts, create a shortcut, and add Open App. Choose PatternVault."))
                Text(String(localized: "Choose Add to Home Screen, enter your name, then tap the icon and choose the exported image from Files."))
            } footer: {
                Text(String(localized: "This adds a separate shortcut. The installed app stays named PatternVault. You can remove its original icon from the Home Screen without deleting the app."))
            }
        }
        .scrollContentBackground(.hidden).background(AlbumTheme.background)
        .navigationTitle(String(localized: "Home Screen name"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AppIconPreview: View {
    let icon: AppIcon
    let size: CGFloat

    var body: some View {
        Image(icon.previewAsset)
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.black.opacity(0.07), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}
