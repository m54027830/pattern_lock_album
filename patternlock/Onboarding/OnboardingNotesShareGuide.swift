import SwiftUI

struct OnboardingNotesShareGuide: View {
    let phrase: String
    let completion: @MainActor (Bool) -> Void
    @State private var showingShareSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text(String(localized: "Choose Notes, then save."))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    VStack(spacing: 12) {
                        NotesShareTrayIllustration()
                        Text(String(localized: "Example share sheet"))
                            .font(.caption).foregroundStyle(AlbumTheme.secondary)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        instruction(1, text: String(localized: "Tap Notes in the app row."))
                        instruction(2, text: String(localized: "Tap Save in Notes to keep your recovery phrase."))
                    }
                    Text(String(localized: "Can’t see Notes? Swipe along the app row or tap More."))
                        .font(.subheadline).foregroundStyle(AlbumTheme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24).frame(maxWidth: 480).frame(maxWidth: .infinity)
            }
            .background(AlbumTheme.background)
            .safeAreaInset(edge: .bottom) {
                Button {
                    showingShareSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Text(String(localized: "Open share sheet"))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "square.and.arrow.up")
                    }
                    .font(.subheadline.weight(.semibold)).padding(20)
                    .foregroundStyle(.white)
                    .vaultPrimarySurface(in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboardingOpenShareSheet")
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: 480).frame(maxWidth: .infinity)
                .background(AlbumTheme.background)
            }
            .navigationTitle(String(localized: "Save to Notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { completion(false) }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                OnboardingPhraseShareSheet(phrase: phrase) { completed in
                    showingShareSheet = false
                    // The system may dismiss its tray before reporting success.
                    // Only its completion callback can finish the guide.
                    if completed { completion(true) }
                }
            }
        }
        .foregroundStyle(AlbumTheme.ink).tint(AlbumTheme.accent)
        .preferredColorScheme(.light)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("onboardingNotesShareGuide")
    }

    private func instruction(_ number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted()).font(.subheadline.weight(.semibold))
                .foregroundStyle(.white).frame(width: 28, height: 28)
                .background(AlbumTheme.accent, in: Circle())
                .accessibilityHidden(true)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NotesShareTrayIllustration: View {
    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Color.gray.opacity(0.3)).frame(width: 34, height: 4)
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 24)).foregroundStyle(AlbumTheme.secondary)
                    .frame(width: 44, height: 48).background(.white, in: RoundedRectangle(cornerRadius: 10))
                Text(String(localized: "Recovery phrase"))
                    .font(.system(size: 14)).foregroundStyle(AlbumTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(AlbumTheme.secondary)
                    .frame(width: 28, height: 28).background(.white, in: Circle())
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                app(label: "AirDrop") {
                    Image(systemName: "airplay.audio")
                        .font(.system(size: 30)).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 14))
                }
                app(label: String(localized: "Notes")) {
                    notesIcon
                        .overlay {
                            Ellipse().stroke(Color(red: 0.85, green: 0.18, blue: 0.2), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .padding(-10).rotationEffect(.degrees(-12))
                        }
                }
                app(label: String(localized: "More")) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 26, weight: .semibold)).foregroundStyle(.gray)
                        .frame(width: 56, height: 56)
                        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.top, 8)
            Divider()
            HStack {
                Text(String(localized: "Copy"))
                Spacer()
                Image(systemName: "doc.on.doc")
            }
            .font(.system(size: 14)).foregroundStyle(AlbumTheme.secondary)
            .padding(14).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 28))
        .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white, lineWidth: 1) }
        .shadow(color: AlbumTheme.ink.opacity(0.08), radius: 12, y: 6)
        // A generic, noninteractive illustration: no phrase, contacts, or shortcuts.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var notesIcon: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(red: 1, green: 0.82, blue: 0.14)).frame(height: 16)
            VStack(spacing: 8) {
                ForEach(0..<3) { _ in Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1) }
            }
            .padding(.horizontal, 9).frame(maxHeight: .infinity)
            .background(Color(white: 0.99))
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.gray.opacity(0.15), lineWidth: 1) }
    }

    private func app<Icon: View>(label: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 15) {
            icon()
            Text(label).font(.system(size: 12)).foregroundStyle(AlbumTheme.ink)
                .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}
