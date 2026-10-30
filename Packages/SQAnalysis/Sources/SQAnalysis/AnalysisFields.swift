import AVFoundation
import CoreVideo
import Foundation
import SQCore
import SQMedia

/// Interlaced media in the analysis readers (mask tracking, Stabilizer, subject detection). A woven frame shows a
/// moving edge as a comb, which tracking and registration follow instead of the picture. The readers take the media
/// item's `VideoTrackInfo.deinterlaceFieldOrder` (the decision the monitors, export and proxies use: nil = progressive
/// or the item's Deinterlace off) and run the app's one pass (`SQMedia.Deinterlacer`) on each frame they use, at the
/// stored size and before shrinking (scaling woven fields blends them).
///
/// nil costs nothing: the reader asks for the same buffers as before and hands them on as they are.
enum AnalysisFields {
    /// What the reader asks the decoder for when the frames get deinterlaced: planar Y'CbCr the pass reads (BGRA it
    /// cannot), 4:2:2 so the chroma rows of both fields survive.
    static let format = kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
    /// Asked for, in this order, when the frames get deinterlaced: a reader that does not take the first (`canAdd`) or
    /// does not start with it gets the next. 4:2:0 is what every decoder hands out; the pass reads it, the chroma of
    /// the two fields is then shared (the luma lines, which tracking follows, stay apart).
    static let fieldFormats: [OSType] = [format, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]

    /// A reader of `track` that has started, with its output. Interlaced media (`order`): the first of `formats` the
    /// reader takes and starts with; with none of them the frames come as stored (BGRA, scaled to `size`), which the
    /// pass hands on woven: analysis of combed frames instead of none. Progressive media: one try, as before.
    /// Throws `StabilizationError.unreadable` when no reader starts.
    static func start(asset: AVAsset, track: AVAssetTrack, order: FieldOrder?, size: (width: Int, height: Int)? = nil,
                      timeRange: CMTimeRange? = nil,
                      formats: [OSType] = fieldFormats) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        var tries: [[String: Any]] = order == nil ? [] : formats.map { readerSettings(order, format: $0) }
        tries.append(readerSettings(nil, size: size))
        for (i, settings) in tries.enumerated() {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            if let timeRange { reader.timeRange = timeRange }
            guard reader.startReading() else { continue }
            if order != nil, i == tries.count - 1 {
                NSLog("[Fields] %@: no planar frames from the reader, analysis reads the frames as stored (woven)",
                      (asset as? AVURLAsset)?.url.lastPathComponent ?? "media")
            }
            return (reader, output)
        }
        throw StabilizationError.unreadable
    }

    /// `AVAssetReaderTrackOutput` settings. `size`: the decoder scales to it; ignored for interlaced media, whose
    /// fields need the stored lines.
    static func readerSettings(_ order: FieldOrder?, size: (width: Int, height: Int)? = nil, format: OSType = format) -> [String: Any] {
        guard order != nil else {
            var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            if let size {
                settings[kCVPixelBufferWidthKey as String] = size.width
                settings[kCVPixelBufferHeightKey as String] = size.height
            }
            return settings
        }
        return [kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    /// The frame analysis looks at: `pb` itself without a field order, else its deinterlaced picture (`pb` again when
    /// the pass cannot read it).
    static func progressive(_ pb: CVPixelBuffer, _ order: FieldOrder?) -> CVPixelBuffer {
        guard let order else { return pb }
        return Deinterlacer.deinterlace(pb, fieldOrder: order)
    }
}
