import AVFoundation
import Foundation
import ImageIO

nonisolated struct MediaFileMetadata: Sendable {
    let date: Date?
    let byteCount: Int64?

    static func read(at url: URL, kind: MediaKind) async -> Self {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]),
              values.isRegularFile == true else { return Self(date: nil, byteCount: nil) }
        let originalDate: Date?
        if kind == .photo {
            originalDate = photoDate(at: url)
        } else if let metadata = try? await AVURLAsset(url: url).load(.creationDate) {
            originalDate = try? await metadata.load(.dateValue)
        } else {
            originalDate = nil
        }
        return Self(date: originalDate ?? values.contentModificationDate ?? values.creationDate,
                    byteCount: values.fileSize.map(Int64.init))
    }

    private static func photoDate(at url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let candidates: [(Any?, Any?)] = [
            (exif?[kCGImagePropertyExifDateTimeOriginal], exif?[kCGImagePropertyExifOffsetTimeOriginal]),
            (exif?[kCGImagePropertyExifDateTimeDigitized], exif?[kCGImagePropertyExifOffsetTimeDigitized]),
            (tiff?[kCGImagePropertyTIFFDateTime], exif?[kCGImagePropertyExifOffsetTime])
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        // EXIF can omit a time zone. Use a stable interpretation on every device.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for (value, offset) in candidates {
            guard let value = value as? String else { continue }
            if let offset = offset as? String {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
                if let date = formatter.date(from: value + offset) { return date }
            }
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
