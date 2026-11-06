import SwiftUI

struct AppIconSettingsView: View {
    @Bindable var icons: AppIconStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(String(localized: "Choose a look for Pattern. This changes the app icon on this device for all vaults."))
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
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(icons.selected == .classic ? [.isSelected] : [])
                .accessibilityIdentifier("appIcon-Classic")

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                    ForEach(AppIcon.allCases.filter { $0 != .classic }) { icon in
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
                            .background(icons.selected == icon ? AlbumTheme.accent.opacity(0.09) : .white.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
                            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(icons.selected == icon ? AlbumTheme.accent : .clear, lineWidth: 2) }
                            .contentShape(RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(icon.title)
                        .accessibilityAddTraits(icons.selected == icon ? [.isSelected] : [])
                        .accessibilityIdentifier("appIcon-" + icon.rawValue)
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
            .disabled(icons.isChanging || !icons.supportsAlternateIcons)
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
