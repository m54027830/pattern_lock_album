import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var store: LibraryStore

    private let vaultName: String
    private let createVault: (() -> Void)?
    private let lockVault: (() -> Void)?

    init(store: LibraryStore? = nil, vaultName: String = "Personal", createVault: (() -> Void)? = nil, lockVault: (() -> Void)? = nil) {
        _store = State(initialValue: store ?? LibraryStore())
        self.vaultName = vaultName
        self.createVault = createVault
        self.lockVault = lockVault
    }
    @State private var currentFolderID: UUID?
    @State private var filter = MediaFilter.all
    @AppStorage("librarySort") private var sort = LibrarySort.newest
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var folderEditor: FolderEditorDestination?
    @State private var folderToDelete: AlbumFolder?
    @State private var showingDelete = false
    @State private var showingMove = false
    @State private var viewer: ViewerDestination?

    private var currentFolder: AlbumFolder? { store.snapshot.folders.first { $0.id == currentFolderID } }
    private var scopedItems: [MediaItem] {
        store.snapshot.items.filter { currentFolderID == nil || $0.folderID == currentFolderID }
    }
    private var visibleItems: [MediaItem] { sort.sorted(scopedItems.filter { filter.includes($0) }) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    filterBar
                    if currentFolderID == nil && !isSelecting { foldersSection }
                    mediaSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(AlbumTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .photosPicker(isPresented: $showingPicker, selection: $pickerItems, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                let destination = currentFolderID
                Task { await store.importItems(items, into: destination); pickerItems = [] }
            }
            .sheet(item: $folderEditor) { destination in
                FolderEditor(folder: destination.folder, store: store)
            }
            .sheet(isPresented: $showingMove) {
                MoveMediaSheet(store: store, selected: selected) { finishSelection() }
            }
            .sheet(item: Binding(get: { viewer == nil ? store.exportSession : nil }, set: { if viewer == nil { store.exportSession = $0 } }), onDismiss: { store.finishExport() }) { session in
                ShareSheet(urls: session.urls) { store.finishExport() }
            }
            .fullScreenCover(item: $viewer) { destination in
                MediaViewer(items: visibleItems, initialID: destination.id, store: store)
            }
            .alert("Something went wrong", isPresented: Binding(get: { store.errorMessage != nil && viewer == nil && folderEditor == nil && !showingMove }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .confirmationDialog("Delete \(selected.count) \(selected.count == 1 ? "item" : "items")?", isPresented: $showingDelete, titleVisibility: .visible) {
                Button("Delete \(selected.count) \(selected.count == 1 ? "item" : "items")", role: .destructive) {
                    Task { if await store.delete(selected) { finishSelection() } }
                }
            } message: { Text("This permanently deletes the selected items from this app. Originals in Photos are unaffected.") }
            .confirmationDialog("Delete folder?", isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }), titleVisibility: .visible) {
                if let folder = folderToDelete {
                    Button("Delete “\(folder.name)”", role: .destructive) {
                        Task {
                            if await store.deleteFolder(folder), currentFolderID == folder.id { currentFolderID = nil }
                            folderToDelete = nil
                        }
                    }
                }
            } message: { Text("The photos and videos inside will stay in All media.") }
            .task { await store.load() }
        }
        .tint(AlbumTheme.accent)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                if currentFolderID != nil {
                    Button { withAnimation { currentFolderID = nil; finishSelection(); filter = .all } } label: {
                        Label("Library", systemImage: "arrow.left").font(.subheadline.weight(.medium))
                    }
                } else {
                    if let createVault, let lockVault {
                        Menu {
                            Text(vaultName)
                            Button("New vault", systemImage: "plus.rectangle.on.folder", action: createVault)
                            Button("Switch vault", systemImage: "arrow.triangle.2.circlepath", action: lockVault)
                            Button("Lock vault", systemImage: "lock", action: lockVault)
                        } label: { vaultLabel }
                        .accessibilityLabel("Vault options, \(vaultName)")
                        .accessibilityIdentifier("vaultOptions")
                    } else { vaultLabel }
                }
                Spacer()
                Button(isSelecting ? "Done" : "Select") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isSelecting { finishSelection() } else { isSelecting = true }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.white, in: Capsule())
                .disabled((visibleItems.isEmpty && !isSelecting) || store.isBusy)
                .accessibilityIdentifier("selectMedia")
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(currentFolder?.name ?? "Library")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .tracking(-1.4)
                        .foregroundStyle(AlbumTheme.ink)
                    Text(currentFolderID == nil ? "Your moments. Your space." : itemCount(scopedItems.count))
                        .font(.subheadline)
                        .foregroundStyle(AlbumTheme.secondary)
                }
                Spacer()
                if let currentFolder {
                    Menu {
                        Button("Edit folder", systemImage: "pencil") { folderEditor = .init(folder: currentFolder) }
                        Button("Delete folder", systemImage: "trash", role: .destructive) { folderToDelete = currentFolder }
                    } label: { Image(systemName: "ellipsis").font(.title3).padding(12).background(.white, in: Circle()) }
                    .disabled(store.isBusy)
                    .accessibilityLabel("Folder options")
                } else {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(AlbumTheme.accent.opacity(0.7))
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var vaultLabel: some View {
        HStack(spacing: 10) {
            PatternMark().frame(width: 26, height: 26)
            Text(vaultName.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2)
                .lineLimit(1)
            if createVault != nil { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .foregroundStyle(AlbumTheme.ink)
        .frame(minHeight: 44)
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            ForEach(MediaFilter.allCases) { choice in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { filter = choice; selected.removeAll() }
                } label: {
                    HStack(spacing: 7) {
                        Text(choice.rawValue).font(.subheadline.weight(.medium))
                        if choice == filter {
                            Text("\(scopedItems.filter { choice.includes($0) }.count)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.white.opacity(0.17), in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .foregroundStyle(choice == filter ? .white : AlbumTheme.secondary)
                    .background(choice == filter ? AlbumTheme.ink : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice == filter ? [.isSelected] : [])
            }
        }
        .padding(5)
        .background(AlbumTheme.track, in: Capsule())
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Folders").font(.headline).foregroundStyle(AlbumTheme.ink)
                Text("\(store.snapshot.folders.count)").font(.caption).foregroundStyle(AlbumTheme.secondary)
                Spacer()
                Button { folderEditor = .init(folder: nil) } label: {
                    Label("New folder", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                }
                .disabled(store.isBusy || !store.isLoaded)
                .accessibilityIdentifier("newFolder")
            }
            if store.snapshot.folders.isEmpty {
                Button { folderEditor = .init(folder: nil) } label: {
                    HStack(spacing: 15) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 25, weight: .light))
                            .frame(width: 52, height: 52).background(AlbumTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("A place for every memory").font(.subheadline.weight(.medium)).foregroundStyle(AlbumTheme.ink)
                            Text("Create a folder to keep things together.").font(.caption).foregroundStyle(AlbumTheme.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .padding(15).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 21))
                }
                .buttonStyle(.plain)
                .disabled(store.isBusy || !store.isLoaded)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.snapshot.folders.sorted { $0.createdAt < $1.createdAt }) { folder in
                            Button { withAnimation { currentFolderID = folder.id; filter = .all } } label: {
                                FolderCard(folder: folder, count: store.snapshot.items.filter { $0.folderID == folder.id }.count)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit folder", systemImage: "pencil") { folderEditor = .init(folder: folder) }
                                Button("Delete folder", systemImage: "trash", role: .destructive) { folderToDelete = folder }
                            }
                            .disabled(store.isBusy)
                        }
                    }
                }
                .contentMargins(.trailing, 1)
            }
        }
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isSelecting ? "\(selected.count) selected" : currentFolderID == nil ? "All media" : "In this folder")
                    .font(.headline).foregroundStyle(AlbumTheme.ink)
                Spacer()
                if isSelecting {
                    Button(selected.count == visibleItems.count ? "Deselect all" : "Select all") {
                        selected = selected.count == visibleItems.count ? [] : Set(visibleItems.map(\.id))
                    }.font(.system(size: 12, weight: .medium))
                } else {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(LibrarySort.allCases) { option in Text(option.rawValue).tag(option) }
                        }
                    } label: {
                        HStack(spacing: 5) { Text(sort.rawValue); Image(systemName: "arrow.up.arrow.down") }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(AlbumTheme.secondary)
                    }
                    .accessibilityLabel("Sort media, \(sort.rawValue)")
                }
            }
            if !store.isLoaded {
                VStack(spacing: 18) {
                    Text(store.errorMessage == nil ? "Opening your library…" : "Your library couldn’t be opened")
                    Button("Try again") { Task { await store.load() } }
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else if visibleItems.isEmpty {
                EmptyLibraryView(filter: filter, isFolder: currentFolderID != nil) { showingPicker = true }
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 5)], spacing: 5) {
                    ForEach(visibleItems) { item in
                        Button {
                            if isSelecting { toggle(item.id) } else { viewer = .init(id: item.id) }
                        } label: {
                            MediaCell(item: item, url: store.repository.thumbnailURL(item), isSelecting: isSelecting, isSelected: selected.contains(item.id))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Select", systemImage: "checkmark.circle") { isSelecting = true; selected = [item.id] }
                            Button("Export", systemImage: "square.and.arrow.up") { Task { await store.export([item.id]) } }
                            Button("Move to folder", systemImage: "folder") { selected = [item.id]; isSelecting = true; showingMove = true }
                            Button("Delete", systemImage: "trash", role: .destructive) { selected = [item.id]; isSelecting = true; showingDelete = true }
                        }
                        .accessibilityLabel("\(item.kind == .video ? "Video" : "Photo"), \(item.originalName)\(selected.contains(item.id) ? ", selected" : "")")
                    }
                }
                .disabled(store.isBusy)
                Text("\(scopedItems.filter { $0.kind == .photo }.count) photos · \(scopedItems.filter { $0.kind == .video }.count) videos")
                    .font(.caption).foregroundStyle(AlbumTheme.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 12)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if store.isBusy {
                HStack(spacing: 10) { ProgressView(); Text(store.progress.isEmpty ? "Saving changes…" : store.progress).font(.caption) }
                    .padding(12).frame(maxWidth: .infinity).background(.regularMaterial)
            }
            HStack(spacing: 16) {
                if isSelecting {
                    selectionAction("Export", icon: "square.and.arrow.up") { Task { await store.export(selected) } }
                    Spacer()
                    selectionAction("Move", icon: "folder") { showingMove = true }
                    Spacer()
                    selectionAction("Delete", icon: "trash", destructive: true) { showingDelete = true }
                } else {
                    HStack(spacing: 7) {
                        Circle().fill(AlbumTheme.accent).frame(width: 5, height: 5)
                        Text("ON THIS DEVICE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.2)
                    }.foregroundStyle(AlbumTheme.secondary)
                    Spacer()
                    Button { showingPicker = true } label: {
                        HStack(spacing: 10) { Image(systemName: "plus").font(.system(size: 17, weight: .medium)); Text("Add media").font(.subheadline.weight(.semibold)) }
                            .foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 16)
                            .background(AlbumTheme.accent, in: Capsule())
                    }
                    .disabled(store.isBusy || !store.isLoaded)
                    .accessibilityIdentifier("addMedia")
                }
            }
            .padding(.horizontal, 27).padding(.vertical, 15)
            .frame(maxWidth: 900).frame(maxWidth: .infinity)
            .background(AlbumTheme.background.opacity(0.97))
            .overlay(alignment: .top) { Rectangle().fill(AlbumTheme.ink.opacity(0.07)).frame(height: 0.5) }
        }
    }

    private func selectionAction(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) { Image(systemName: icon).font(.system(size: 20)); Text(title).font(.caption.weight(.medium)) }
                .frame(minWidth: 60, minHeight: 48)
        }
        .foregroundStyle(destructive ? Color.red : AlbumTheme.accent)
        .disabled(selected.isEmpty || store.isBusy)
        .opacity(selected.isEmpty ? 0.35 : 1)
    }

    private func toggle(_ id: UUID) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    private func finishSelection() { isSelecting = false; selected.removeAll() }
    private func itemCount(_ count: Int) -> String { "\(count) \(count == 1 ? "item" : "items")" }
}

struct FolderEditorDestination: Identifiable { let id = UUID(); let folder: AlbumFolder? }
struct ViewerDestination: Identifiable { let id: UUID }

#Preview { ContentView() }
