import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store: LibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.detail

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
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @AppStorage("librarySort") private var sort = LibrarySort.newest
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var showingDocuments = false
    @State private var showingCamera = false
    @State private var addDestination: VaultAddAction?
    @State private var importFolderID: UUID?
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
    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleItems: [MediaItem] {
        let query = searchQuery
        return sort.sorted(scopedItems.filter {
            filter.includes($0) && (query.isEmpty || $0.originalName.localizedStandardContains(query))
        })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            folderSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            library
        }
        .navigationSplitViewStyle(.balanced)
        .tint(AlbumTheme.accent)
        .preferredColorScheme(.light)
    }

    private var folderSidebar: some View {
        List(selection: Binding<LibraryLocation?>(get: {
            currentFolderID.map(LibraryLocation.folder) ?? .library
        }, set: { location in
            guard let location else { return }
            switch location {
            case .library: currentFolderID = nil
            case .folder(let id): currentFolderID = id
            }
            finishSelection()
            filter = .all
            compactColumn = .detail
        })) {
            NavigationLink(value: LibraryLocation.library) {
                Label(String(localized: "Library"), systemImage: "photo.on.rectangle")
            }
            Section(String(localized: "Folders")) {
                ForEach(store.snapshot.folders.sorted { $0.createdAt < $1.createdAt }) { folder in
                    NavigationLink(value: LibraryLocation.folder(folder.id)) {
                        Label(folder.name, systemImage: "folder")
                    }
                }
                if !store.isReadOnly {
                    Button { folderEditor = .init(folder: nil) } label: {
                        Label(String(localized: "New folder"), systemImage: "folder.badge.plus")
                    }
                    .disabled(store.isBusy || !store.isLoaded)
                }
            }
        }
        .disabled(store.isBusy)
        .navigationTitle(vaultName)
        .toolbar(removing: .sidebarToggle)
        .scrollContentBackground(.hidden)
        .background(AlbumTheme.background)
    }

    private var library: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    libraryToolbar
                    if currentFolderID == nil && !isSelecting && (horizontalSizeClass != .regular || columnVisibility == .detailOnly) && (!store.isReadOnly || !store.snapshot.folders.isEmpty) { foldersSection }
                    mediaSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AlbumTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .photosPicker(isPresented: $showingPicker, selection: $pickerItems, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                let destination = importFolderID
                Task { await store.importItems(items, into: destination); pickerItems = [] }
            }
            .fileImporter(isPresented: $showingDocuments, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let destination = importFolderID
                    Task { await store.importDocuments(urls, into: destination) }
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
            }
            .sheet(item: $addDestination) { destination in
                if destination == .memo { MemoComposer(store: store, folderID: importFolderID) }
            }
            .fullScreenCover(isPresented: $showingCamera) { VaultCameraView(store: store, folderID: importFolderID) }
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
            .alert(String(localized: "Something went wrong"), isPresented: Binding(get: { store.errorMessage != nil && viewer == nil && folderEditor == nil && addDestination == nil && !showingCamera && !showingMove }, set: { if !$0 { store.errorMessage = nil } })) {
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
            } message: { Text(String(localized: "The items inside will stay in your library.")) }
            .task { await store.load(); scheduleCloudUpdate() }
            .onChange(of: store.snapshot) { _, _ in scheduleCloudUpdate() }
            .onChange(of: filter) { _, _ in selected.removeAll() }
            .onChange(of: searchText) { _, _ in selected.formIntersection(visibleItems.map(\.id)) }
            .onChange(of: currentFolderID) { _, _ in
                searchText = ""
                isSearchFocused = false
            }
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

    private func requestAdd(_ action: VaultAddAction) {
        guard !store.isReadOnly, !store.isBusy, store.isLoaded else { return }
        do {
            try store.repository.purchaseAccess.checkMediaAddition(currentCount: store.snapshot.items.count)
            importFolderID = currentFolderID
            filter = .all
            searchText = ""
            isSearchFocused = false
            switch action {
            case .media: showingPicker = true
            case .document: showingDocuments = true
            case .memo: addDestination = action
            case .camera: showingCamera = true
            }
        } catch { showingUpgrade = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if horizontalSizeClass == .regular {
                    Button {
                        withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
                    } label: {
                        Image(systemName: "sidebar.left").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(String(localized: "Folders"))
                }
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
                                .font(.system(size: 18)).frame(width: 44, height: 44).vaultMetalSurface(in: Circle())
                        }
                        .disabled(store.isBusy)
                        .accessibilityLabel(String(localized: "New vault")).accessibilityIdentifier("newVault")
                    }
                    if let lockVault {
                        Button(action: lockVault) {
                            Image(systemName: "lock")
                                .font(.system(size: 18)).frame(width: 44, height: 44).vaultMetalSurface(in: Circle())
                        }
                        .accessibilityLabel(String(localized: "Lock vault")).accessibilityIdentifier("lockVault")
                    }
                }
                if vault != nil {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 44, height: 44).vaultMetalSurface(in: Circle())
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
                    } label: { Image(systemName: "ellipsis").font(.title3).padding(12).vaultMetalSurface(in: Circle()) }
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
            isSearchFocused = false
            withAnimation(.easeInOut(duration: 0.2)) {
                if isSelecting { finishSelection() } else { isSelecting = true }
            }
        } label: {
            toolbarIcon(isSelecting ? "checkmark.circle.fill" : "checkmark.circle", isActive: isSelecting)
        }
        .disabled((visibleItems.isEmpty && !isSelecting) || store.isBusy)
        .accessibilityLabel(isSelecting ? String(localized: "Done") : String(localized: "Select"))
        .accessibilityAddTraits(isSelecting ? [.isSelected] : [])
        .accessibilityRemoveTraits(isSelecting ? [] : [.isSelected])
        .accessibilityIdentifier("selectMedia")
        .help(isSelecting ? String(localized: "Done") : String(localized: "Select"))
    }

    private var libraryToolbar: some View {
        HStack(spacing: 8) {
            searchField
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Menu {
                    Picker(String(localized: "Sort by"), selection: $sort) {
                        ForEach(LibrarySort.allCases) { option in Text(option.title).tag(option) }
                    }
                } label: {
                    toolbarIcon("arrow.up.arrow.down")
                }
                .accessibilityLabel(String(localized: "Sort media, \(sort.title)"))
                .accessibilityIdentifier("sortMedia")
                .help(String(localized: "Sort by"))

                Menu {
                    Picker(String(localized: "Filter"), selection: $filter) {
                        ForEach(MediaFilter.allCases) { choice in Text(choice.title).tag(choice) }
                    }
                } label: {
                    toolbarIcon("line.3.horizontal.decrease", isActive: filter != .all)
                }
                .accessibilityLabel(String(localized: "Filter"))
                .accessibilityValue(filter.title)
                .accessibilityIdentifier("filterMedia")
                .help(String(localized: "Filter"))

                selectionButton
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AlbumTheme.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "Search"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit { isSearchFocused = false }
                .accessibilityLabel(String(localized: "Search by name"))
                .accessibilityIdentifier("searchMedia")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AlbumTheme.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .font(.subheadline)
        .foregroundStyle(AlbumTheme.ink)
        .padding(.leading, 12)
        .padding(.trailing, searchText.isEmpty ? 12 : 0)
        .frame(maxWidth: 360, minHeight: 44)
        .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 14))
    }

    private func toolbarIcon(_ symbol: String, isActive: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isActive ? .white : AlbumTheme.accent)
            .frame(width: 44, height: 44)
            .background(isActive ? .clear : AlbumTheme.surface, in: Circle())
            .vaultPrimarySurface(in: Circle(), prominent: isActive)
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
                    .padding(15).vaultMetalSurface(in: RoundedRectangle(cornerRadius: 21))
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
                if !searchQuery.isEmpty || filter != .all {
                    ContentUnavailableView(String(localized: "No matching items"), systemImage: "magnifyingglass",
                                           description: Text(String(localized: "Try a different name or filter.")))
                } else if store.isReadOnly {
                    ContentUnavailableView(String(localized: "This shared vault is empty"), systemImage: "photo.on.rectangle")
                } else {
                    EmptyLibraryView(add: requestAdd).padding(.vertical, 8)
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
                        .accessibilityLabel(item.accessibilityLabel)
                        .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
                        .accessibilityIdentifier("mediaItem-\(item.id.uuidString)")
                    }
                }
                .disabled(store.isBusy)
                Text(itemCount(visibleItems.count))
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
            HStack(spacing: 0) {
                if isSelecting {
                    if store.allowsExport { selectionAction(String(localized: "Export"), icon: "square.and.arrow.up") { Task { await store.export(selected) } } }
                    Spacer(minLength: 0)
                    if !store.isReadOnly { selectionAction(String(localized: "Move"), icon: "folder") { showingMove = true }
                    Spacer(minLength: 0)
                    selectionAction(String(localized: "Delete"), icon: "trash", destructive: true) { showingDelete = true } }
                } else if !store.isReadOnly {
                    Spacer()
                    VaultAddMenu(action: requestAdd)
                    .disabled(store.isBusy || !store.isLoaded)
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
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 48)
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
private enum LibraryLocation: Hashable { case library, folder(UUID) }

#Preview { ContentView() }
