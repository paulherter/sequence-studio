import AVFoundation
import Foundation
import ImageIO
import SQCore

/// When and with what a file was shot: container creation date and camera model. Best-effort (nil on any error).
/// Feeds the Project panel's camera / day filters and its "Sorted by" views.
public enum ShootMetadata {
    public struct Result: Sendable, Equatable {
        public var created: Date?
        public var cameraModel: String?
    }

    /// Reads one file. `sonyModel` is the model the import already got from Sony's metadata; `walkedBoxes` says the caller
    /// already looked for it (saves a second walk over the boxes).
    public static func read(_ url: URL, sonyModel: String? = nil, walkedBoxes: Bool = false) async -> Result {
        if StillImage.isStill(url) { return readStill(url) }
        let asset = AVURLAsset(url: url)
        var created: Date?
        if let item = try? await asset.load(.creationDate) { created = try? await item.load(.dateValue) }
        var model = clean(sonyModel)
        var make: String?
        if let items = try? await asset.load(.metadata) {
            for item in items {
                let id = item.identifier?.rawValue.lowercased() ?? ""
                let common = item.commonKey?.rawValue
                if model == nil, common == "model" || id.hasSuffix("model") {
                    model = clean(try? await item.load(.stringValue))
                } else if make == nil, common == "make" || id.hasSuffix("make") {
                    make = clean(try? await item.load(.stringValue))
                }
            }
        }
        if model == nil { model = make }
        if model == nil, !walkedBoxes, let sony = CameraMetadata.read(forClip: url).sony?.modelName { model = clean(sony) }
        return Result(created: created, cameraModel: model)
    }

    /// Still image: EXIF / TIFF model and original date.
    static func readStill(_ url: URL) -> Result {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return Result() }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var date: Date?
        if let s = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            date = f.date(from: s)
        }
        return Result(created: date, cameraModel: clean(tiff?[kCGImagePropertyTIFFModel] as? String) ?? clean(tiff?[kCGImagePropertyTIFFMake] as? String))
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !t.isEmpty else { return nil }
        return t
    }
}
