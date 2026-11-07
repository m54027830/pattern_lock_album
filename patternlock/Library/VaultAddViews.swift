import SwiftUI

enum VaultAddAction: CaseIterable, Identifiable {
    case media, camera, memo, document
    var id: Self { self }
    var title: String {
        switch self {
        case .media: String(localized: "Media")
        case .camera: String(localized: "Camera")
        case .memo: String(localized: "Memo")
        case .document: String(localized: "Document")
        }
    }
    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .camera: "camera"
        case .memo: "square.and.pencil"
        case .document: "doc.badge.plus"
        }
    }
}

struct VaultAddMenu: View {
    var prominent = true
    let action: (VaultAddAction) -> Void

    var body: some View {
        Menu {
            ForEach(VaultAddAction.allCases) { choice in
                Button(choice.title, systemImage: choice.symbol) { action(choice) }
                    .accessibilityIdentifier("add-\(choice)")
            }
        } label: {
            Label(String(localized: "Add"), systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(prominent ? .white : AlbumTheme.accent)
                .padding(.horizontal, 22).padding(.vertical, 16)
                .background(prominent ? AlbumTheme.accent : .clear, in: Capsule())
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier(prominent ? "addMedia" : "addFirstItem")
    }
}

struct MemoComposer: View {
    let store: LibraryStore
    let folderID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField(String(localized: "Title"), text: $title)
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("memoTitle")
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(String(localized: "Memo"))
                    .accessibilityIdentifier("memoBody")
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            .padding(24).background(AlbumTheme.background)
            .navigationTitle(String(localized: "New memo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }.disabled(store.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        Task {
                            if await store.saveMemo(title: title, body: text, into: folderID) { dismiss() }
                            else { error = store.errorMessage; store.errorMessage = nil }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
                    .accessibilityIdentifier("saveMemo")
                }
            }
            .overlay { if store.isBusy { ProgressView() } }
            .onAppear { focused = true }
            .interactiveDismissDisabled(!text.isEmpty || store.isBusy)
        }
        .tint(AlbumTheme.accent)
    }
}
