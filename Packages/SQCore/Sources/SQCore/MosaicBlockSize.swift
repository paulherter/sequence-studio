import Foundation

/// A Mosaic grid: how many blocks across and down.
public struct MosaicGrid: Sendable, Hashable {
    public var columns: Int
    public var rows: Int
    public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }
}

// F7.11: Mosaic by block size. The stored effect stays Columns / Rows (no new parameter key, so nothing changes in the
// project file); a block size is turned into the grid of square blocks for the clip's own frame when the effect is made.
// The soft edge of a Mosaic that covers only a part of the picture is the Feather of the mask it takes as its input.
extension ClipEffect {
    /// Columns / Rows range of the Mosaic effect (its catalog range).
    static let mosaicGridRange = 1...4_000

    /// The grid whose blocks are squares of about `blockSize` px on a `width` x `height` frame.
    public static func mosaicGrid(blockSize: Double, width: Int, height: Int) -> MosaicGrid {
        let b = max(blockSize, 1)
        func count(_ px: Int) -> Int {
            min(max(Int((Double(max(px, 1)) / b).rounded()), mosaicGridRange.lowerBound), mosaicGridRange.upperBound)
        }
        return MosaicGrid(columns: count(width), rows: count(height))
    }

    /// A Mosaic effect with square blocks of about `blockSize` px on a `width` x `height` frame.
    public static func mosaic(blockSize: Double, width: Int, height: Int) -> ClipEffect {
        let g = mosaicGrid(blockSize: blockSize, width: width, height: height)
        var p = defaultParameters(for: mosaicKind)
        p[mosaicColumnsKey] = AnimatedProperty(Double(g.columns))
        p[mosaicRowsKey] = AnimatedProperty(Double(g.rows))
        return ClipEffect(kind: mosaicKind, parameters: p)
    }

    /// Block size (px of the clip's frame) Anonymize starts with: about eight blocks across the covered subject, and never
    /// finer than 1/60 of the frame's short side, so a subject that is small in the frame is not left readable.
    public static func anonymizeBlockSize(subjectWidth: Double, frameWidth: Int, frameHeight: Int) -> Double {
        let floor = (Double(min(frameWidth, frameHeight)) / 60).rounded()
        return max((subjectWidth / 8).rounded(), floor, 1)
    }
}
