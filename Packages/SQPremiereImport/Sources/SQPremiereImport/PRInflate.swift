import Foundation
import SQCore

/// Raw deflate for platforms without the Compression framework (Windows); the decoder itself is `SQCore.RawInflate`
/// (shared with the PNG reader). Throws `corruptArchive` for bad input or output beyond `limit`.
enum PRInflate {
    static func inflate(_ src: [UInt8], limit: Int) throws -> Data {
        do { return try RawInflate.inflate(src, limit: limit) } catch { throw PRImportError.corruptArchive }
    }
}
