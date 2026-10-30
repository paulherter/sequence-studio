import Foundation
import SQDrawKit

/// Timeline thumbnails packed into one image slot: a fixed grid of cells, each holding one decoded frame scaled to fit
/// (aspect kept). The least recently used cell is reused when the grid is full. The host uploads `image` to `slot`
/// whenever `generation` changes and answers `TimelineMediaSource.picture` from `picture(for:)`.
/// Not thread-safe: the host keeps it behind its own lock.
public struct ThumbnailAtlas: Sendable {
    /// A cached frame: media and a host-chosen frame number (the Windows host uses milliseconds of media time).
    public struct Key: Hashable, Sendable {
        public var media: UUID
        public var frame: Int
        public init(media: UUID, frame: Int) { self.media = media; self.frame = frame }
    }

    public let slot: Int
    public let cellWidth: Int, cellHeight: Int
    public let columns: Int, rows: Int
    public private(set) var image: RGBAImage
    /// Bumped on every change of `image`.
    public private(set) var generation = 0

    private struct Entry { var cell: Int; var size: (w: Int, h: Int); var used: Int }
    private var entries: [Key: Entry] = [:]
    private var owner: [Key?]
    private var clock = 0

    public init(slot: Int, cellWidth: Int = 160, cellHeight: Int = 90, columns: Int = 12, rows: Int = 22) {
        self.slot = slot
        self.cellWidth = cellWidth; self.cellHeight = cellHeight; self.columns = columns; self.rows = rows
        image = RGBAImage(width: cellWidth * columns, height: cellHeight * rows,
                          pixels: [UInt8](repeating: 0, count: cellWidth * columns * cellHeight * rows * 4))
        owner = Array(repeating: nil, count: columns * rows)
    }

    public var capacity: Int { columns * rows }
    public var count: Int { entries.count }
    public func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// The cell of `key` as a picture (marks it recently used); nil when it is not cached.
    public mutating func picture(for key: Key) -> TimelinePicture? {
        guard var e = entries[key] else { return nil }
        clock += 1
        e.used = clock
        entries[key] = e
        return picture(e)
    }

    /// Scales `frame` to fit a cell (area average, aspect kept) and stores it under `key`, reusing the least recently
    /// used cell when the grid is full.
    public mutating func insert(_ key: Key, frame: RGBAImage) {
        guard frame.width > 0, frame.height > 0 else { return }
        let k = min(Double(cellWidth) / Double(frame.width), Double(cellHeight) / Double(frame.height), 1)
        let w = max(1, Int((Double(frame.width) * k).rounded())), h = max(1, Int((Double(frame.height) * k).rounded()))
        let cell: Int
        if let e = entries[key] {
            cell = e.cell
        } else if let free = owner.firstIndex(where: { $0 == nil }) {
            cell = free
        } else {
            let (old, e) = entries.min { $0.value.used < $1.value.used }!
            entries[old] = nil
            cell = e.cell
        }
        owner[cell] = key
        clock += 1
        entries[key] = Entry(cell: cell, size: (w, h), used: clock)
        blit(Self.scaled(frame, width: w, height: h), cell: cell)
        generation += 1
    }

    private func picture(_ e: Entry) -> TimelinePicture {
        let aw = Float(image.width), ah = Float(image.height)
        let x = Float((e.cell % columns) * cellWidth), y = Float((e.cell / columns) * cellHeight)
        // Half a texel in from the cell's edges so bilinear sampling never reads the neighbor cell.
        let u0 = (x + 0.5) / aw, v0 = (y + 0.5) / ah
        let u1 = (x + Float(e.size.w) - 0.5) / aw, v1 = (y + Float(e.size.h) - 0.5) / ah
        return TimelinePicture(slot: slot, source: (u0, v0, u1, v1), pixelSize: CGSize(width: e.size.w, height: e.size.h))
    }

    private mutating func blit(_ src: RGBAImage, cell: Int) {
        let x0 = (cell % columns) * cellWidth, y0 = (cell / columns) * cellHeight
        let stride = image.width * 4
        image.pixels.withUnsafeMutableBufferPointer { dst in
            src.pixels.withUnsafeBufferPointer { s in
                for row in 0..<src.height {
                    let d = (y0 + row) * stride + x0 * 4
                    for i in 0..<(src.width * 4) { dst[d + i] = s[row * src.width * 4 + i] }
                }
            }
        }
    }

    /// Area-average downscale (each output pixel averages the source box it covers).
    static func scaled(_ src: RGBAImage, width w: Int, height h: Int) -> RGBAImage {
        if src.width == w, src.height == h { return src }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        src.pixels.withUnsafeBufferPointer { p in
            for oy in 0..<h {
                let sy0 = oy * src.height / h, sy1 = max(sy0 + 1, (oy + 1) * src.height / h)
                for ox in 0..<w {
                    let sx0 = ox * src.width / w, sx1 = max(sx0 + 1, (ox + 1) * src.width / w)
                    var acc = (0, 0, 0, 0)
                    for sy in sy0..<sy1 {
                        var i = (sy * src.width + sx0) * 4
                        for _ in sx0..<sx1 {
                            acc.0 += Int(p[i]); acc.1 += Int(p[i + 1]); acc.2 += Int(p[i + 2]); acc.3 += Int(p[i + 3])
                            i += 4
                        }
                    }
                    let n = (sy1 - sy0) * (sx1 - sx0), o = (oy * w + ox) * 4
                    out[o] = UInt8(acc.0 / n); out[o + 1] = UInt8(acc.1 / n)
                    out[o + 2] = UInt8(acc.2 / n); out[o + 3] = UInt8(acc.3 / n)
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }
}
