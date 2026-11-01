import ImageIO
import SwiftUI
import UIKit

@MainActor enum AlbumTheme {
    static let background = Color(red: 0.965, green: 0.961, blue: 0.945)
    static let ink = Color(red: 0.14, green: 0.20, blue: 0.19)
    static let accent = Color(red: 0.22, green: 0.38, blue: 0.32)
    static let secondary = Color(red: 0.48, green: 0.51, blue: 0.48)
    static let track = Color(red: 0.91, green: 0.92, blue: 0.89)
    static let folderColors: [Color] = [
        Color(red: 0.83, green: 0.88, blue: 0.79),
        Color(red: 0.91, green: 0.83, blue: 0.71),
        Color(red: 0.79, green: 0.85, blue: 0.90),
        Color(red: 0.88, green: 0.80, blue: 0.80),
        Color(red: 0.84, green: 0.80, blue: 0.90),
        Color(red: 0.86, green: 0.86, blue: 0.81)
    ]
    static let colorNames = ["Sage", "Sand", "Sky", "Rose", "Lilac", "Stone"]
    static func folderColor(_ index: Int) -> Color { folderColors[max(0, min(index, folderColors.count - 1))] }
}

struct PatternMark: View {
    var body: some View {
        Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { col in
                        Circle().fill(AlbumTheme.accent.opacity(row == col || col == 2 ? 1 : 0.23)).frame(width: 5, height: 5)
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
            Text("\(count) \(count == 1 ? "item" : "items")").font(.caption).opacity(0.6).padding(.top, 5)
        }
        .foregroundStyle(AlbumTheme.ink)
        .padding(17).frame(width: 150, alignment: .leading)
        .background(AlbumTheme.folderColor(folder.colorIndex).opacity(0.65), in: RoundedRectangle(cornerRadius: 20))
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
                else { Rectangle().fill(AlbumTheme.track).overlay { Image(systemName: item.kind == .video ? "video" : "photo").foregroundStyle(AlbumTheme.secondary) } }
            }
            .overlay {
                if item.kind == .video { LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom) }
                if isSelected { AlbumTheme.accent.opacity(0.2) }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    HStack(spacing: 4) { Image(systemName: "play.fill").font(.system(size: 8)); Text(item.durationLabel).font(.system(size: 10, weight: .semibold).monospacedDigit()) }
                        .foregroundStyle(.white).padding(9)
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
            .task(id: url) { image = await ImageLoader.shared.image(at: url) }
    }
}

struct EmptyLibraryView: View {
    let filter: MediaFilter
    let isFolder: Bool
    let add: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 17).fill(AlbumTheme.folderColor(0).opacity(0.5))
                    .frame(width: 78, height: 96).rotationEffect(.degrees(-14)).offset(x: -20, y: 0)
                RoundedRectangle(cornerRadius: 17).fill(.white)
                    .frame(width: 78, height: 96).rotationEffect(.degrees(10)).offset(x: 18, y: 4)
                    .shadow(color: AlbumTheme.ink.opacity(0.06), radius: 14, y: 6)
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 31, weight: .ultraLight))
                    .foregroundStyle(AlbumTheme.accent).offset(x: 10, y: 2)
            }
            .frame(height: 105).padding(.bottom, 2).accessibilityHidden(true)
            Text(filter == .all ? (isFolder ? "Make room for memories" : "Your story starts here") : "No \(filter.rawValue.lowercased()) yet")
                .font(.system(size: 21, weight: .medium, design: .rounded)).foregroundStyle(AlbumTheme.ink)
            Text(isFolder ? "Add photos and videos to this folder,\nor move some from your library." : "Add the photos and videos you want\nto keep close. Just for you.")
                .font(.subheadline).lineSpacing(4).multilineTextAlignment(.center).foregroundStyle(AlbumTheme.secondary)
            Button(action: add) { Label("Add your first \(filter == .videos ? "video" : "photos")", systemImage: "plus").font(.subheadline.weight(.semibold)) }
                .padding(.top, 3)
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
                    .background(AlbumTheme.folderColor(colorIndex), in: RoundedRectangle(cornerRadius: 25))
                    .frame(maxWidth: .infinity).padding(.top, 15)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Folder name").font(.subheadline.weight(.semibold))
                    TextField("e.g. Weekend escapes", text: $name).focused($focused)
                        .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .submitLabel(.done).onSubmit { save() }
                        .accessibilityIdentifier("folderName")
                }
                VStack(alignment: .leading, spacing: 13) {
                    Text("Color").font(.subheadline.weight(.semibold))
                    HStack(spacing: 15) {
                        ForEach(AlbumTheme.folderColors.indices, id: \.self) { index in
                            Button { colorIndex = index } label: {
                                Circle().fill(AlbumTheme.folderColor(index)).frame(width: 37, height: 37)
                                    .overlay { if index == colorIndex { Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(AlbumTheme.ink) } }
                            }.accessibilityLabel(AlbumTheme.colorNames[index])
                                .accessibilityAddTraits(index == colorIndex ? [.isSelected] : [])
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Button(action: save) {
                    Text(folder == nil ? "Create folder" : "Save changes").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(17).background(AlbumTheme.accent, in: Capsule())
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
                    .accessibilityIdentifier("saveFolder")
                Spacer(minLength: 0)
            }
            .padding(25).background(AlbumTheme.background)
            .navigationTitle(folder == nil ? "New folder" : "Edit folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
                    Button { move(to: nil) } label: { Label("No folder", systemImage: "square.grid.2x2") }
                    ForEach(store.snapshot.folders) { folder in
                        Button { move(to: folder.id) } label: {
                            Label { Text(folder.name) } icon: { Image(systemName: "folder.fill").foregroundStyle(AlbumTheme.folderColor(folder.colorIndex)) }
                        }
                    }
                } header: { Text("Move \(selected.count) \(selected.count == 1 ? "item" : "items") to") }
                Section { Button { creatingFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") } }
            }
            .disabled(store.isBusy)
            .scrollContentBackground(.hidden).background(AlbumTheme.background)
            .navigationTitle("Move to folder").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $creatingFolder) { FolderEditor(folder: nil, store: store) }
            .alert("Couldn’t move items", isPresented: Binding(get: { store.errorMessage != nil && !creatingFolder }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
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
