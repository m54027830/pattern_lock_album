import ImageIO
import UIKit
import XCTest
@testable import patternlock

@MainActor final class MediaSortingTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "SortTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func photo(at url: URL, date: String? = nil, offset: String? = nil) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }
        var exif: [CFString: Any] = [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = date
        exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(image.cgImage), [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
    }

    private func item(_ number: Int, added: TimeInterval, fileDate: TimeInterval?, bytes: Int64?) -> MediaItem {
        MediaItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!, filename: "\(number).jpg", originalName: "\(number)",
                  kind: number.isMultiple(of: 2) ? .video : .photo, importedAt: Date(timeIntervalSince1970: added), duration: nil, folderID: nil,
                  fileDate: fileDate.map { Date(timeIntervalSince1970: $0) }, byteCount: bytes)
    }

    func testFileDateAndSizeSortsUseOriginalMetadataWithStableTies() {
        let a = item(1, added: 300, fileDate: 10, bytes: 900)
        let b = item(2, added: 200, fileDate: 50, bytes: 100)
        let c = item(3, added: 100, fileDate: 50, bytes: 100)
        let missing = item(4, added: 40, fileDate: nil, bytes: nil)
        let zero = item(5, added: 0, fileDate: 0, bytes: 0)
        let items = [missing, c, a, zero, b]
        XCTAssertEqual(LibrarySort.fileDate.sorted(items).map(\.id), [b, c, missing, a, zero].map(\.id))
        XCTAssertEqual(LibrarySort.largest.sorted(items).map(\.id), [a, b, c, zero, missing].map(\.id))
        XCTAssertEqual(LibrarySort.smallest.sorted(items).map(\.id), [zero, b, c, a, missing].map(\.id))
        XCTAssertEqual(LibrarySort.newest.sorted(items).map(\.id), [a, b, c, missing, zero].map(\.id))
        XCTAssertEqual(LibrarySort(rawValue: "Newest first"), .newest)
        XCTAssertEqual(LibrarySort(rawValue: "Oldest first"), .oldest)
        XCTAssertEqual(LibrarySort(rawValue: "Name"), .name)
    }

    func testPhotoImportPreservesEXIFDateTimeZoneAndOriginalSizeAcrossRelaunch() async throws {
        let root = try workspace(), source = root.appending(path: "dated.jpg")
        try photo(at: source, date: "2020:01:02 12:30:00", offset: "+09:00")
        let bytes = try Data(contentsOf: source)
        let repository = LibraryRepository(root: root.appending(path: "Vault"))
        let imported = try await repository.importFile(at: source, originalName: "dated.jpg", kind: .photo, folderID: nil)
        let media = try XCTUnwrap(imported.items.first)
        XCTAssertEqual(media.fileDate, ISO8601DateFormatter().date(from: "2020-01-02T03:30:00Z"))
        XCTAssertEqual(media.byteCount, Int64(bytes.count))
        XCTAssertNotEqual(media.fileDate, media.importedAt)
        XCTAssertEqual(try Data(contentsOf: repository.mediaURL(media)), bytes)
        let restarted = try await LibraryRepository(root: repository.root).loadForDisplay()
        XCTAssertEqual(restarted, imported)
    }

    func testFileTimestampFallbackAndMissingFiles() async throws {
        let root = try workspace(), source = root.appending(path: "undated.jpg")
        try photo(at: source, date: "not a date")
        let timestamp = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
        let repository = LibraryRepository(root: root.appending(path: "Vault"))
        let imported = try await repository.importFile(at: source, originalName: "undated.jpg", kind: .photo, folderID: nil)
        XCTAssertEqual(imported.items.first?.fileDate, timestamp)
        let missing = await MediaFileMetadata.read(at: root.appending(path: "missing.mov"), kind: .video)
        XCTAssertNil(missing.date)
        XCTAssertNil(missing.byteCount)
    }

    func testLegacyLibraryBackfillsMetadataWithoutChangingMediaOrFolders() async throws {
        let root = try workspace(), originals = root.appending(path: "Originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let source = originals.appending(path: "1.jpg")
        try photo(at: source, date: "2018:06:07 08:09:10")
        let originalBytes = try Data(contentsOf: source)
        let folder = AlbumFolder(id: UUID(), name: "Keep", colorIndex: 1, createdAt: Date())
        var media = item(1, added: 1_700_000_000, fileDate: nil, bytes: nil)
        media.folderID = folder.id
        let legacy = LibrarySnapshot(folders: [folder], items: [media, item(2, added: 200, fileDate: nil, bytes: nil)])
        let manifest = root.appending(path: "library.json")
        let oldJSON = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("fileDate"))
        try oldJSON.write(to: manifest)
        let repository = LibraryRepository(root: root)
        let decoded = try await repository.load()
        XCTAssertEqual(decoded, legacy)
        let loaded = try await repository.loadForDisplay()
        XCTAssertEqual(loaded.folders, legacy.folders)
        XCTAssertEqual(loaded.items.map(\.id), legacy.items.map(\.id))
        XCTAssertEqual(loaded.items[0].folderID, folder.id)
        XCTAssertEqual(loaded.items[0].importedAt, media.importedAt)
        XCTAssertEqual(loaded.items[0].fileDate, ISO8601DateFormatter().date(from: "2018-06-07T08:09:10Z"))
        XCTAssertEqual(loaded.items[0].byteCount, Int64(originalBytes.count))
        XCTAssertNil(loaded.items[1].byteCount, "Missing originals must not prevent the library from opening")
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        let restarted = try await LibraryRepository(root: root).load()
        XCTAssertEqual(restarted, loaded)
    }
}
