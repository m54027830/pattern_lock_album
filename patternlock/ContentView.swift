import Photos
import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var store: LibraryStore

    private let vaultName: String
    private let createVault: (() -> Void)?
    private let lockVault: (() -> Void)?
    private let vault: Vault?
    private let onVaultChanged: ((Vault) -> Void)?
    private let onVaultDeleted: (() -> Void)?

    init(store: LibraryStore? = nil, vaultName: String = String(localized: "Personal"), createVault: (() -> Void)? = nil, lockVault: (() -> Void)? = nil, vault: Vault? = nil, onVaultChanged: ((Vault) -> Void)? = nil, onVaultDeleted: (() -> Void)? = nil) {
        _store = State(initialValue: store ?? LibraryStore())
        self.vaultName = vaultName
        self.createVault = createVault
        self.lockVault = lockVault
        self.vault = vault
        self.onVaultChanged = onVaultChanged
        self.onVaultDeleted = onVaultDeleted
    }
    @State private var cloudTask: Task<Void, Never>?
    @State private var cloud = VaultCloudService.shared
    @State private var currentFolderID: UUID?
    @State private var filter = MediaFilter.all
    @AppStorage("librarySort") private var sort = LibrarySort.newest
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var showingUpgrade = false
    @State private var showingImportResult = false
    @State private var showingSettings = false
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
                    if currentFolderID == nil && !isSelecting && (!store.isReadOnly || !store.snapshot.folders.isEmpty) { foldersSection }
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
            .photosPicker(isPresented: $showingPicker, selection: $pickerItems, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                let destination = currentFolderID
                Task { await store.importItems(items, into: destination); pickerItems = [] }
            }
            .sheet(isPresented: $showingUpgrade) { PurchaseView(reason: .media) }
            .sheet(item: $store.purchaseLimit) { PurchaseView(reason: $0) }
            .sheet(item: $folderEditor) { destination in
                FolderEditor(folder: destination.folder, store: store)
            }
            .sheet(isPresented: $showingSettings) {
                if let vault {
                    VaultSettingsView(store: store, vault: vault, onVaultChanged: { onVaultChanged?($0) }, onDeleted: { onVaultDeleted?() })
                }
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
            .alert(String(localized: "Something went wrong"), isPresented: Binding(get: { store.errorMessage != nil && viewer == nil && folderEditor == nil && !showingMove }, set: { if !$0 { store.errorMessage = nil } })) {
                Button(String(localized: "OK"), role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onChange(of: store.importSummary?.id, initial: true) { _, id in
                showingImportResult = id != nil
            }
            .alert(String(localized: "Import complete"), isPresented: $showingImportResult, presenting: store.importSummary) { summary in
                Button(String(localized: "Keep originals"), role: .cancel) { store.dismissImportSummary() }
                if summary.limitSkippedCount > 0 {
                    Button(String(localized: "Unlock Unlimited")) { store.dismissImportSummary(); showingUpgrade = true }
                }
                if !summary.originals.isEmpty {
                    Button(String(localized: "Delete originals from Photos"), role: .destructive) {
                        Task { await store.deleteImportedOriginals(summaryID: summary.id) }
                    }
                }
            } message: { summary in Text(summary.message) }
            .confirmationDialog(String(localized: "Delete \(selected.count) items?"), isPresented: $showingDelete, titleVisibility: .visible) {
                Button(String(localized: "Delete \(selected.count) items"), role: .destructive) {
                    Task { if await store.delete(selected) { finishSelection() } }
                }
            } message: { Text(String(localized: "This permanently deletes the selected items from this app. Originals in Photos are unaffected.")) }
            .confirmationDialog(String(localized: "Delete folder?"), isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }), titleVisibility: .visible) {
                if let folder = folderToDelete {
                    Button(String(localized: "Delete “\(folder.name)”"), role: .destructive) {
                        Task {
                            if await store.deleteFolder(folder), currentFolderID == folder.id { currentFolderID = nil }
                            folderToDelete = nil
                        }
                    }
                }
            } message: { Text(String(localized: "The photos and videos inside will stay in All media.")) }
            .task { await store.load(); scheduleCloudUpdate() }
            .onChange(of: store.snapshot) { _, _ in scheduleCloudUpdate() }
            .onChange(of: vaultName) { _, _ in scheduleCloudUpdate() }
            .onDisappear { cloudTask?.cancel() }
        }
        .tint(AlbumTheme.accent)
        .preferredColorScheme(.light)
    }

    private func scheduleCloudUpdate() {
        guard let vault, !store.isReadOnly else { return }
        cloudTask?.cancel()
        cloudTask = Task {
            do {
                try await Task.sleep(for: .seconds(3))
                while store.isBusy { try await Task.sleep(for: .seconds(1)) }
                try await cloud.synchronize(vault: vault, store: store)
            } catch { /* Status remains visible in cloud settings; retry on next open/change. */ }
        }
    }

    private func requestImport() {
        guard !store.isReadOnly else { return }
        do {
            try store.repository.purchaseAccess.checkMediaAddition(currentCount: store.snapshot.items.count)
            showingPicker = true
        } catch { showingUpgrade = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if currentFolderID != nil {
                    Button { withAnimation { currentFolderID = nil; finishSelection(); filter = .all } } label: {
                        Label(String(localized: "Library"), systemImage: "arrow.left").font(.subheadline.weight(.medium))
                    }
                } else { vaultLabel }
                Spacer(minLength: 8)
                if currentFolderID == nil {
                    if let createVault {
                        Button(action: createVault) {
                            Image(systemName: "rectangle.stack.badge.plus")
                                .font(.system(size: 18)).frame(width: 44, height: 44).background(.white, in: Circle())
                        }
                        .disabled(store.isBusy)
                        .accessibilityLabel(String(localized: "New vault")).accessibilityIdentifier("newVault")
                    }
                    if let lockVault {
                        Button(action: lockVault) {
                            Image(systemName: "lock")
                                .font(.system(size: 18)).frame(width: 44, height: 44).background(.white, in: Circle())
                        }
                        .accessibilityLabel(String(localized: "Lock vault")).accessibilityIdentifier("lockVault")
                    }
                }
                if vault != nil {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 44, height: 44).background(.white, in: Circle())
                    }
                    .disabled(store.isBusy)
                    .accessibilityLabel(String(localized: "Vault settings")).accessibilityIdentifier("vaultSettings")
                }
            }
            if let currentFolder {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(currentFolder.name)
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .tracking(-1.4)
                            .foregroundStyle(AlbumTheme.ink)
                        Text(itemCount(scopedItems.count))
                            .font(.subheadline)
                            .foregroundStyle(AlbumTheme.secondary)
                    }
                    Spacer()
                    if !store.isReadOnly { Menu {
                        Button(String(localized: "Edit folder"), systemImage: "pencil") { folderEditor = .init(folder: currentFolder) }
                        Button(String(localized: "Delete folder"), systemImage: "trash", role: .destructive) { folderToDelete = currentFolder }
                    } label: { Image(systemName: "ellipsis").font(.title3).padding(12).background(.white, in: Circle()) }
                    .disabled(store.isBusy)
                    .accessibilityLabel(String(localized: "Folder options")) }
                }
            }
        }
    }

    private var vaultLabel: some View {
        HStack(spacing: 8) {
            PatternMark().frame(width: 26, height: 26)
            Text(vaultName.uppercased())
                .font(.system(size: 14, weight: .semibold, design: .monospaced)).tracking(2)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityLabel(vaultName)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("vaultName")
        }
        .foregroundStyle(AlbumTheme.ink)
        .frame(minHeight: 44, alignment: .leading)
    }

    private var selectionButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isSelecting { finishSelection() } else { isSelecting = true }
            }
        } label: {
            Label(isSelecting ? String(localized: "Done") : String(localized: "Select"), systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelecting ? .white : AlbumTheme.accent)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(isSelecting ? AlbumTheme.accent : .white, in: Capsule())
        }
        .disabled((visibleItems.isEmpty && !isSelecting) || store.isBusy)
        .accessibilityLabel(isSelecting ? String(localized: "Done") : String(localized: "Select"))
        .accessibilityAddTraits(isSelecting ? [.isSelected] : [])
        .accessibilityRemoveTraits(isSelecting ? [] : [.isSelected])
        .accessibilityIdentifier("selectMedia")
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            ForEach(MediaFilter.allCases) { choice in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { filter = choice; selected.removeAll() }
                } label: {
                    HStack(spacing: 7) {
                        Text(choice.title).font(.subheadline.weight(.medium))
                        if choice == filter {
                            Text(String(localized: "\(scopedItems.filter { choice.includes($0) }.count)"))
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
                Text(String(localized: "Folders")).font(.headline).foregroundStyle(AlbumTheme.ink)
                Text(String(localized: "\(store.snapshot.folders.count)")).font(.caption).foregroundStyle(AlbumTheme.secondary)
                Spacer()
                if !store.isReadOnly { Button { folderEditor = .init(folder: nil) } label: {
                    Label(String(localized: "New folder"), systemImage: "plus").font(.system(size: 12, weight: .semibold))
                }
                .disabled(store.isBusy || !store.isLoaded)
                .accessibilityIdentifier("newFolder") }
            }
            if store.snapshot.folders.isEmpty {
                Button { folderEditor = .init(folder: nil) } label: {
                    HStack(spacing: 15) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 25, weight: .light))
                            .frame(width: 52, height: 52).background(AlbumTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(String(localized: "A place for every memory")).font(.subheadline.weight(.medium)).foregroundStyle(AlbumTheme.ink)
                            Text(String(localized: "Create a folder to keep things together.")).font(.caption).foregroundStyle(AlbumTheme.secondary)
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
                                if !store.isReadOnly {
                                Button(String(localized: "Edit folder"), systemImage: "pencil") { folderEditor = .init(folder: folder) }
                                Button(String(localized: "Delete folder"), systemImage: "trash", role: .destructive) { folderToDelete = folder }
                                }
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
                Menu {
                    Picker(String(localized: "Sort by"), selection: $sort) {
                        ForEach(LibrarySort.allCases) { option in Text(option.title).tag(option) }
                    }
                } label: {
                    HStack(spacing: 5) { Text(sort.title); Image(systemName: "arrow.up.arrow.down") }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AlbumTheme.secondary)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel(String(localized: "Sort media, \(sort.title)"))
                Spacer()
                selectionButton
            }
            if isSelecting {
                HStack {
                    Text(String(localized: "\(selected.count) selected"))
                        .font(.headline).foregroundStyle(AlbumTheme.ink)
                    Spacer()
                    Button(selected.count == visibleItems.count ? String(localized: "Deselect all") : String(localized: "Select all")) {
                        selected = selected.count == visibleItems.count ? [] : Set(visibleItems.map(\.id))
                    }.font(.system(size: 12, weight: .medium))
                }
            }
            if !store.isLoaded {
                VStack(spacing: 18) {
                    Text(store.errorMessage == nil ? String(localized: "Opening your library…") : String(localized: "Your library couldn’t be opened"))
                    Button(String(localized: "Try again")) { Task { await store.load() } }
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else if visibleItems.isEmpty {
                if store.isReadOnly {
                    ContentUnavailableView(String(localized: "This shared vault is empty"), systemImage: "photo.on.rectangle")
                } else {
                    EmptyLibraryView(filter: filter, isFolder: currentFolderID != nil) { requestImport() }.padding(.vertical, 8)
                }
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
                            Button(String(localized: "Select"), systemImage: "checkmark.circle") { isSelecting = true; selected = [item.id] }
                            if store.allowsExport { Button(String(localized: "Export"), systemImage: "square.and.arrow.up") { Task { await store.export([item.id]) } } }
                            if !store.isReadOnly {
                            Button(String(localized: "Move to folder"), systemImage: "folder") { selected = [item.id]; isSelecting = true; showingMove = true }
                            Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) { selected = [item.id]; isSelecting = true; showingDelete = true }
                            }
                        }
                        .accessibilityLabel(item.kind == .video ? String(localized: "Video, \(item.originalName)") : String(localized: "Photo, \(item.originalName)"))
                        .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
                        .accessibilityIdentifier("mediaItem-\(item.id.uuidString)")
                    }
                }
                .disabled(store.isBusy)
                Text(String(localized: "Photos: \(scopedItems.filter { $0.kind == .photo }.count) · Videos: \(scopedItems.filter { $0.kind == .video }.count)"))
                    .font(.caption).foregroundStyle(AlbumTheme.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 12)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if store.isBusy {
                HStack(spacing: 10) { ProgressView(); Text(store.progress.isEmpty ? String(localized: "Saving changes…") : store.progress).font(.caption) }
                    .padding(12).frame(maxWidth: .infinity).background(.regularMaterial)
            }
            HStack(spacing: 16) {
                if isSelecting {
                    if store.allowsExport { selectionAction(String(localized: "Export"), icon: "square.and.arrow.up") { Task { await store.export(selected) } } }
                    Spacer()
                    if !store.isReadOnly { selectionAction(String(localized: "Move"), icon: "folder") { showingMove = true }
                    Spacer()
                    selectionAction(String(localized: "Delete"), icon: "trash", destructive: true) { showingDelete = true } }
                } else if !store.isReadOnly {
                    Spacer()
                    Button { requestImport() } label: {
                        HStack(spacing: 10) { Image(systemName: "plus").font(.system(size: 17, weight: .medium)); Text(String(localized: "Add media")).font(.subheadline.weight(.semibold)) }
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
    private func itemCount(_ count: Int) -> String { String(localized: "\(count) items") }
}

struct FolderEditorDestination: Identifiable { let id = UUID(); let folder: AlbumFolder? }
struct ViewerDestination: Identifiable { let id: UUID }

#Preview { ContentView() }
