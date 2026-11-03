import AVFoundation
import UIKit
import XCTest
@testable import patternlock

@MainActor final class LibraryRepositoryTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "LibraryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func photo(in root: URL) throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let url = root.appending(path: "original.jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    func testImportMoveRenameRelaunchAndDeletePreserveSource() async throws {
        let root = try workspace()
        let source = try photo(in: root)
        let repository = LibraryRepository(root: root.appending(path: "Library"))
        let folders = try await repository.createFolder(name: "Travel", colorIndex: 2)
        let folder = try XCTUnwrap(folders.folders.first)
        let imported = try await repository.importFile(at: source, originalName: "Trip.jpg", kind: .photo, folderID: folder.id)
        let item = try XCTUnwrap(imported.items.first)
        XCTAssertEqual(item.folderID, folder.id)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: repository.mediaURL(item)))
        XCTAssertNotNil(UIImage(contentsOfFile: repository.thumbnailURL(item).path))
        let renamed = try await repository.renameFolder(id: folder.id, name: "Japan", colorIndex: 1)
        XCTAssertEqual(renamed.folders.first?.name, "Japan")
        let fresh = LibraryRepository(root: repository.root)
        let reloaded = try await fresh.load()
        XCTAssertEqual(reloaded, renamed)
        let unfiled = try await repository.move(ids: [item.id], to: nil)
        XCTAssertNil(unfiled.items.first?.folderID)
        _ = try await repository.move(ids: [item.id], to: folder.id)
        let removedFolder = try await repository.deleteFolder(id: folder.id)
        XCTAssertEqual(removedFolder.items.count, 1)
        XCTAssertNil(removedFolder.items.first?.folderID)
        let deleted = try await repository.delete(ids: [item.id])
        XCTAssertTrue(deleted.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.mediaURL(item).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.thumbnailURL(item).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let lastLaunch = try await LibraryRepository(root: repository.root).load()
        XCTAssertTrue(lastLaunch.items.isEmpty)
    }

    func testNamesAreTrimmedAndDuplicatesRejected() async throws {
        let repository = LibraryRepository(root: try workspace())
        let created = try await repository.createFolder(name: "  Travel  ", colorIndex: 0)
        XCTAssertEqual(created.folders.first?.name, "Travel")
        do { _ = try await repository.createFolder(name: "travel", colorIndex: 0); XCTFail("Duplicate accepted") }
        catch { XCTAssertTrue(error is LibraryError) }
        do { _ = try await repository.createFolder(name: "   ", colorIndex: 0); XCTFail("Blank accepted") }
        catch { XCTAssertTrue(error is LibraryError) }
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.folders.count, 1)
    }

    func testInvalidImportLeavesNoOrphans() async throws {
        let root = try workspace()
        let invalid = root.appending(path: "invalid.jpg")
        try Data("not an image".utf8).write(to: invalid)
        let repository = LibraryRepository(root: root.appending(path: "Library"))
        do { _ = try await repository.importFile(at: invalid, originalName: "invalid.jpg", kind: .photo, folderID: nil); XCTFail("Invalid image accepted") }
        catch { }
        let loaded = try await repository.load()
        XCTAssertTrue(loaded.items.isEmpty)
        let originals = try FileManager.default.contentsOfDirectory(at: repository.root.appending(path: "Originals"), includingPropertiesForKeys: nil)
        XCTAssertTrue(originals.isEmpty)
    }

    func testUnreadableManifestIsNotReplaced() async throws {
        let root = try workspace()
        let manifest = root.appending(path: "library.json")
        let original = Data("corrupted manifest".utf8)
        try original.write(to: manifest)
        let repository = LibraryRepository(root: root)
        do { _ = try await repository.load(); XCTFail("Corrupt manifest accepted") }
        catch { XCTAssertTrue(error is LibraryError) }
        do { _ = try await repository.createFolder(name: "New", colorIndex: 0); XCTFail("Corrupt manifest overwritten") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: manifest), original)
    }

    func testExportPreservesBytesAndDuplicateNames() async throws {
        let root = try workspace()
        let source = try photo(in: root)
        let repository = LibraryRepository(root: root.appending(path: "Library"))
        _ = try await repository.importFile(at: source, originalName: "Holiday.jpg", kind: .photo, folderID: nil)
        let imported = try await repository.importFile(at: source, originalName: "Holiday.jpg", kind: .photo, folderID: nil)
        let export = try await repository.export(ids: Set(imported.items.map(\.id)))
        defer { try? FileManager.default.removeItem(at: export) }
        let files = try FileManager.default.contentsOfDirectory(at: export, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["Holiday.jpg", "Holiday (2).jpg"])
        for file in files { XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: source)) }
    }

    func testInterruptedDeleteRestoresFilesBeforeOpeningLibrary() async throws {
        let root = try workspace()
        let source = try photo(in: root)
        let repository = LibraryRepository(root: root.appending(path: "Library"))
        let imported = try await repository.importFile(at: source, originalName: "Original.jpg", kind: .photo, folderID: nil)
        let item = try XCTUnwrap(imported.items.first)
        let staging = repository.root.appending(path: "Deleting-interrupted")
        try FileManager.default.createDirectory(at: staging.appending(path: "Originals"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: repository.mediaURL(item), to: staging.appending(path: "Originals").appending(path: item.filename))
        let recovered = try await LibraryRepository(root: repository.root).load()
        XCTAssertEqual(recovered.items, imported.items)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.mediaURL(item).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testFailedManifestWriteRollsBackDeletion() async throws {
        let root = try workspace()
        let source = try photo(in: root)
        let repository = LibraryRepository(root: root.appending(path: "Library"))
        let imported = try await repository.importFile(at: source, originalName: "Original.jpg", kind: .photo, folderID: nil)
        let item = try XCTUnwrap(imported.items.first)
        let manifest = repository.root.appending(path: "library.json")
        let savedManifest = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        do { _ = try await repository.delete(ids: [item.id]); XCTFail("Unwritable manifest accepted") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: repository.mediaURL(item)), try Data(contentsOf: source))
        XCTAssertNotNil(UIImage(contentsOfFile: repository.thumbnailURL(item).path))
        try FileManager.default.removeItem(at: manifest)
        try savedManifest.write(to: manifest)
        let recovered = try await repository.load()
        XCTAssertEqual(recovered.items, imported.items)
    }

    func testLocalLibraryIsExcludedFromDeviceBackupAndUsesFileProtection() async throws {
        let root = try workspace()
        let repository = LibraryRepository(root: root)
        _ = try await repository.createFolder(name: "Backup", colorIndex: 0)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        // The simulator does not emulate iOS Data Protection attributes.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appending(path: "library.json").path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
        #endif
    }

    func testVideoImportCreatesPlayableOriginalAndThumbnail() async throws {
        let root = try workspace()
        let video = root.appending(path: "clip.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        let creationDate = AVMutableMetadataItem()
        creationDate.identifier = .quickTimeMetadataCreationDate
        creationDate.value = "2019-08-07T06:05:04+09:00" as NSString
        creationDate.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [creationDate]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 80, AVVideoHeightKey: 80])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 80, kCVPixelBufferHeightKey as String: 80])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 80, 80, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 100, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let repository = LibraryRepository(root: root.appending(path: "Library"))
        let imported = try await repository.importFile(at: video, originalName: "Clip.mov", kind: .video, folderID: nil)
        let item = try XCTUnwrap(imported.items.first)
        XCTAssertEqual(item.kind, .video)
        XCTAssertGreaterThan(item.duration ?? 0, 0)
        let expectedDate = ISO8601DateFormatter().date(from: "2019-08-06T21:05:04Z")
        XCTAssertEqual(item.fileDate, expectedDate)
        XCTAssertEqual(item.byteCount, Int64(try Data(contentsOf: video).count))
        XCTAssertNotNil(UIImage(contentsOfFile: repository.thumbnailURL(item).path))
        XCTAssertEqual(try Data(contentsOf: video), try Data(contentsOf: repository.mediaURL(item)))
        var legacy = imported
        legacy.items[0].fileDate = nil
        legacy.items[0].byteCount = nil
        try JSONEncoder().encode(legacy).write(to: repository.root.appending(path: "library.json"))
        let upgraded = try await LibraryRepository(root: repository.root).loadForDisplay()
        XCTAssertEqual(upgraded.items[0].fileDate, expectedDate)
        XCTAssertEqual(upgraded.items[0].byteCount, item.byteCount)
    }
}
