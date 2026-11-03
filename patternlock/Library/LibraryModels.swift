import Foundation

nonisolated enum MediaKind: String, Codable, Sendable {
    case photo, video
}

nonisolated struct MediaItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let originalName: String
    let kind: MediaKind
    let importedAt: Date
    let duration: Double?
    var folderID: UUID?

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
    var id: String { rawValue }
    // Keep persisted raw values stable; only the displayed title is localized.
    var title: String {
        switch self {
        case .newest: String(localized: "Newest first")
        case .oldest: String(localized: "Oldest first")
        case .name: String(localized: "Name")
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
            }
        }
    }
}

nonisolated enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .photos: String(localized: "Photos")
        case .videos: String(localized: "Videos")
        }
    }
    func includes(_ item: MediaItem) -> Bool {
        self == .all || (self == .photos && item.kind == .photo) || (self == .videos && item.kind == .video)
    }
}

nonisolated enum LibraryError: LocalizedError {
    case invalidName, duplicateFolder, missingFolder, unsupportedMedia, unreadableLibrary, newerLibrary

    var errorDescription: String? {
        switch self {
        case .invalidName: String(localized: "Give your folder a name between 1 and 60 characters.")
        case .duplicateFolder: String(localized: "A folder with that name already exists.")
        case .missingFolder: String(localized: "That folder is no longer available.")
        case .unsupportedMedia: String(localized: "This file could not be read as a photo or video.")
        case .unreadableLibrary: String(localized: "The library could not be opened. Your saved files have been kept. Try reopening the app.")
        case .newerLibrary: String(localized: "This library was created by a newer version of the app. Update the app to open it.")
        }
    }
}
