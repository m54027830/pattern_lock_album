import Foundation

nonisolated enum MediaKind: String, Codable, Sendable {
    case photo, video, memo, document

    var symbol: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .memo: "note.text"
        case .document: "doc.text"
        }
    }

    var defaultExtension: String {
        switch self {
        case .photo: "jpg"
        case .video: "mov"
        case .memo: "txt"
        case .document: ""
        }
    }
}

nonisolated struct MediaItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let originalName: String
    let kind: MediaKind
    let importedAt: Date
    let duration: Double?
    var folderID: UUID?
    // Optional so existing libraries and older encrypted backups still decode.
    var fileDate: Date? = nil
    var byteCount: Int64? = nil

    var accessibilityLabel: String {
        switch kind {
        case .photo: String(localized: "Photo, \(originalName)")
        case .video: String(localized: "Video, \(originalName)")
        case .memo: String(localized: "Memo, \(originalName)")
        case .document: String(localized: "Document, \(originalName)")
        }
    }

    var durationLabel: String {
        let seconds = Int(max(0, duration ?? 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

nonisolated struct AlbumFolder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var colorIndex: Int
    let createdAt: Date
}

nonisolated struct LibrarySnapshot: Codable, Equatable, Sendable {
    var version = 1
    var folders: [AlbumFolder] = []
    var items: [MediaItem] = []
}

nonisolated enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case name = "Name"
    case fileDate = "File date"
    case largest = "Largest first"
    case smallest = "Smallest first"
    var id: String { rawValue }
    // Keep persisted raw values stable; only the displayed title is localized.
    var title: String {
        switch self {
        case .newest: String(localized: "Newest first")
        case .oldest: String(localized: "Oldest first")
        case .name: String(localized: "Name")
        case .fileDate: String(localized: "File date")
        case .largest: String(localized: "Largest first")
        case .smallest: String(localized: "Smallest first")
        }
    }

    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { lhs, rhs in
            switch self {
            case .newest: return lhs.importedAt == rhs.importedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.importedAt > rhs.importedAt
            case .oldest: return lhs.importedAt == rhs.importedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.importedAt < rhs.importedAt
            case .name:
                let result = lhs.originalName.localizedStandardCompare(rhs.originalName)
                return result == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : result == .orderedAscending
            case .fileDate:
                let left = lhs.fileDate ?? lhs.importedAt, right = rhs.fileDate ?? rhs.importedAt
                return left == right ? lhs.id.uuidString < rhs.id.uuidString : left > right
            case .largest, .smallest:
                // Unreadable/missing files go last in either direction.
                guard let left = lhs.byteCount else { return rhs.byteCount == nil && lhs.id.uuidString < rhs.id.uuidString }
                guard let right = rhs.byteCount else { return true }
                if left == right { return lhs.id.uuidString < rhs.id.uuidString }
                return self == .largest ? left > right : left < right
            }
        }
    }
}

nonisolated enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos", memos = "Memos", documents = "Documents"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .photos: String(localized: "Photos")
        case .videos: String(localized: "Videos")
        case .memos: String(localized: "Memos")
        case .documents: String(localized: "Documents")
        }
    }
    func includes(_ item: MediaItem) -> Bool {
        switch self {
        case .all: true
        case .photos: item.kind == .photo
        case .videos: item.kind == .video
        case .memos: item.kind == .memo
        case .documents: item.kind == .document
        }
    }
}

nonisolated enum LibraryError: LocalizedError, Equatable {
    case invalidName, duplicateFolder, missingFolder, unsupportedMedia, unreadableLibrary, newerLibrary, invalidDocument, emptyMemo

    var errorDescription: String? {
        switch self {
        case .invalidName: String(localized: "Give your folder a name between 1 and 60 characters.")
        case .duplicateFolder: String(localized: "A folder with that name already exists.")
        case .missingFolder: String(localized: "That folder is no longer available.")
        case .unsupportedMedia: String(localized: "This file could not be read as a photo or video.")
        case .unreadableLibrary: String(localized: "The library could not be opened. Your saved files have been kept. Try reopening the app.")
        case .newerLibrary: String(localized: "This library was created by a newer version of the app. Update the app to open it.")
        case .invalidDocument: String(localized: "This file could not be imported. Choose a downloaded file, not a folder.")
        case .emptyMemo: String(localized: "Write something in your memo before saving.")
        }
    }
}
