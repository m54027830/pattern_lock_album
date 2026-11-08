import ImageIO
import SwiftUI
import UIKit

@MainActor enum AlbumTheme {
    // Cool steel surfaces and navy controls echo the primary vault icon.
    static let background = color(0xE8EDF3)
    static let surface = color(0xF4F7FA)
    static let ink = color(0x17273D)
    static let accent = Color("AccentColor")
    static let secondary = color(0x4E6179)
    static let track = color(0xD5DFE9)
    static let border = color(0xB3C3D4)
    static let selectedSurface = color(0xDCE7F2)
    static let accentGradient = LinearGradient(colors: [color(0x47678A), color(0x213751)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let edgeGradient = LinearGradient(colors: [.white.opacity(0.95), border], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let folderColors: [Color] = [
        color(0xB3C3D6), color(0xD9E1EA), color(0xC3D9EF),
        color(0x9DADC2), color(0xDDE9F2), color(0xAAB5C3)
    ]
    // Keep the six persisted color indices; only their visual palette changes.
    static let colorNames = [String(localized: "Steel"), String(localized: "Silver"), String(localized: "Sky"), String(localized: "Slate"), String(localized: "Ice"), String(localized: "Graphite")]
    static func folderColor(_ index: Int) -> Color { folderColors[max(0, min(index, folderColors.count - 1))] }

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

@MainActor extension View {
    func vaultMetalSurface<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        background {
            shape.fill(LinearGradient(colors: [.white, tint ?? AlbumTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { shape.strokeBorder(AlbumTheme.edgeGradient, lineWidth: 1) }
                .shadow(color: AlbumTheme.ink.opacity(0.06), radius: 5, y: 3)
                .allowsHitTesting(false)
        }
    }

    func vaultPrimarySurface<S: InsettableShape>(in shape: S, prominent: Bool = true) -> some View {
        background {
            if prominent {
                shape.fill(AlbumTheme.accentGradient)
                    .overlay { shape.strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                    .shadow(color: AlbumTheme.ink.opacity(0.16), radius: 4, y: 3)
            }
        }
    }
}

struct PatternMark: View {
    var body: some View {
        Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { col in
                        Circle().fill(AlbumTheme.accent).frame(width: 5, height: 5)
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}

struct FolderCard: View {
    let folder: AlbumFolder
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "folder.fill").font(.system(size: 27, weight: .light))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).opacity(0.5)
            }.padding(.bottom, 23)
            Text(folder.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(String(localized: "\(count) items")).font(.caption).padding(.top, 5)
        }
        .foregroundStyle(AlbumTheme.ink)
        .padding(17).frame(width: 150, alignment: .leading)
        .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 20), tint: AlbumTheme.folderColor(folder.colorIndex))
    }
}

actor ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 50 * 1024 * 1024 }
    func image(at url: URL, maxPixels: Int = 600) -> UIImage? {
        let key = (url.path + "-\(maxPixels)") as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}

struct MediaCell: View {
    let item: MediaItem
    let url: URL
    let isSelecting: Bool
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(0.88, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(AlbumTheme.track).overlay { Image(systemName: item.kind.symbol).foregroundStyle(AlbumTheme.secondary) } }
            }
            .overlay {
                if item.kind == .video { LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom) }
                if isSelected { AlbumTheme.accent.opacity(0.2) }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    HStack(spacing: 4) { Image(systemName: "play.fill").font(.system(size: 8)); Text(item.durationLabel).font(.system(size: 10, weight: .semibold).monospacedDigit()) }
                        .foregroundStyle(.white).padding(9)
                } else if item.kind == .memo || item.kind == .document {
                    Label(item.originalName, systemImage: item.kind.symbol)
                        .font(.caption2.weight(.medium)).lineLimit(2)
                        .foregroundStyle(AlbumTheme.ink).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isSelected ? AlbumTheme.accent : .white)
                        .background(isSelected ? .white : .black.opacity(0.15), in: Circle())
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? AlbumTheme.accent : .clear, lineWidth: 3) }
            // Aspect-fill images can extend past the visible crop. Clipping only
            // affects drawing; constrain taps to this tile so neighbors cannot
            // intercept selection, opening, or a long press.
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 12))
            .task(id: url) { image = await ImageLoader.shared.image(at: url) }
    }
}

struct EmptyLibraryView: View {
    let add: (VaultAddAction) -> Void
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 17).fill(AlbumTheme.folderColor(0).gradient)
                    .frame(width: 78, height: 96).rotationEffect(.degrees(-14)).offset(x: -20, y: 0)
                RoundedRectangle(cornerRadius: 17).fill(AlbumTheme.surface.gradient)
                    .frame(width: 78, height: 96).rotationEffect(.degrees(10)).offset(x: 18, y: 4)
                    .shadow(color: AlbumTheme.ink.opacity(0.06), radius: 14, y: 6)
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 31, weight: .ultraLight))
                    .foregroundStyle(AlbumTheme.accent).offset(x: 10, y: 2)
            }
            .frame(height: 105).padding(.bottom, 2).accessibilityHidden(true)
            Text(String(localized: "Nothing here yet"))
                .font(.system(size: 21, weight: .medium, design: .rounded)).foregroundStyle(AlbumTheme.ink)
            Text(String(localized: "Keep photos, videos, memos, and documents in your vault."))
                .font(.subheadline).lineSpacing(4).multilineTextAlignment(.center).foregroundStyle(AlbumTheme.secondary)
            VaultAddMenu(prominent: false, action: add).padding(.top, 3)
        }.frame(maxWidth: .infinity)
    }
}

struct FolderEditor: View {
    let folder: AlbumFolder?
    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorIndex = 0
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 25) {
                Image(systemName: "folder.fill").font(.system(size: 45, weight: .light))
                    .foregroundStyle(AlbumTheme.accent).frame(width: 90, height: 90)
                    .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 25), tint: AlbumTheme.folderColor(colorIndex))
                    .frame(maxWidth: .infinity).padding(.top, 15)
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Folder name")).font(.subheadline.weight(.semibold))
                    TextField(String(localized: "e.g. Weekend escapes"), text: $name).focused($focused)
                        .padding(16).vaultMetalSurface(in: RoundedRectangle(cornerRadius: 14))
                        .submitLabel(.done).onSubmit { save() }
                        .accessibilityIdentifier("folderName")
                }
                VStack(alignment: .leading, spacing: 13) {
                    Text(String(localized: "Color")).font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(AlbumTheme.folderColors.indices, id: \.self) { index in
                            Button { colorIndex = index } label: {
                                Circle().fill(AlbumTheme.folderColor(index).gradient).frame(width: 37, height: 37)
                                    .overlay { Circle().strokeBorder(index == colorIndex ? AlbumTheme.accent : AlbumTheme.border, lineWidth: index == colorIndex ? 2 : 1) }
                                    .overlay { if index == colorIndex { Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(AlbumTheme.ink) } }
                            }.frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel(AlbumTheme.colorNames[index])
                                .accessibilityAddTraits(index == colorIndex ? [.isSelected] : [])
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Button(action: save) {
                    Text(folder == nil ? String(localized: "Create folder") : String(localized: "Save changes")).font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(17).vaultPrimarySurface(in: Capsule())
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
                    .accessibilityIdentifier("saveFolder")
                Spacer(minLength: 0)
            }
            .padding(25).background(AlbumTheme.background)
            .navigationTitle(folder == nil ? String(localized: "New folder") : String(localized: "Edit folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } } }
            .onAppear { name = folder?.name ?? ""; colorIndex = folder?.colorIndex ?? 0 }
        }
        .presentationDetents([.height(510), .large])
        .presentationDragIndicator(.visible)
        .tint(AlbumTheme.accent)
    }

    private func save() {
        focused = false
        Task {
            if await store.saveFolder(folder, name: name, colorIndex: colorIndex) { dismiss() }
            else { error = store.errorMessage; store.errorMessage = nil }
        }
    }
}

struct MoveMediaSheet: View {
    @Bindable var store: LibraryStore
    let selected: Set<UUID>
    let completion: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var creatingFolder = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { move(to: nil) } label: { Label(String(localized: "No folder"), systemImage: "square.grid.2x2") }
                    ForEach(store.snapshot.folders) { folder in
                        Button { move(to: folder.id) } label: {
                            Label { Text(folder.name) } icon: { Image(systemName: "folder.fill").foregroundStyle(AlbumTheme.folderColor(folder.colorIndex)) }
                        }
                    }
                } header: { Text(String(localized: "Move \(selected.count) items to")) }
                Section { Button { creatingFolder = true } label: { Label(String(localized: "New folder"), systemImage: "folder.badge.plus") } }
            }
            .disabled(store.isBusy)
            .scrollContentBackground(.hidden).background(AlbumTheme.background)
            .navigationTitle(String(localized: "Move to folder")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } } }
            .sheet(isPresented: $creatingFolder) { FolderEditor(folder: nil, store: store) }
            .alert(String(localized: "Couldn’t move items"), isPresented: Binding(get: { store.errorMessage != nil && !creatingFolder }, set: { if !$0 { store.errorMessage = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }.tint(AlbumTheme.accent).presentationDetents([.medium, .large])
    }
    private func move(to id: UUID?) {
        Task { if await store.move(selected, to: id) { completion(); dismiss() } }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
