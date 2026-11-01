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
    func includes(_ item: MediaItem) -> Bool {
        self == .all || (self == .photos && item.kind == .photo) || (self == .videos && item.kind == .video)
    }
}

nonisolated enum LibraryError: LocalizedError {
    case invalidName, duplicateFolder, missingFolder, unsupportedMedia, unreadableLibrary, newerLibrary

    var errorDescription: String? {
        switch self {
        case .invalidName: "Give your folder a name between 1 and 60 characters."
        case .duplicateFolder: "A folder with that name already exists."
        case .missingFolder: "That folder is no longer available."
        case .unsupportedMedia: "This file could not be read as a photo or video."
        case .unreadableLibrary: "The library could not be opened. Your saved files have been kept. Try reopening the app."
        case .newerLibrary: "This library was created by a newer version of the app. Update the app to open it."
        }
    }
}
