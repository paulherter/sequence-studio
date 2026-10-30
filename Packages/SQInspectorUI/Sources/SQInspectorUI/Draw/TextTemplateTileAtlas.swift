import Foundation
import SQDrawKit
import SQText

/// Where a template tile's picture sits in the atlas: the image slot and the normalized source rect.
public struct TextTemplateTilePicture: Equatable, Sendable {
    public var slot: Int
    public var source: (Float, Float, Float, Float)
    public init(slot: Int, source: (Float, Float, Float, Float)) { self.slot = slot; self.source = source }
    public static func == (a: Self, b: Self) -> Bool {
        a.slot == b.slot && a.source.0 == b.source.0 && a.source.1 == b.source.1 && a.source.2 == b.source.2
            && a.source.3 == b.source.3
    }
}

/// The pictures of the Text panel's template tiles, packed into one image slot (`slot`): the Mac `TextTemplateTileView`
/// picture, i.e. the saved PNG of a multi-layer template, else the template's look drawn by the real text renderer
/// (`TextPresetStill`, with its outline, box and shadow) on the tile background, at the Mac's 256 x 160 pixels. Tiles
/// without either keep the sample text the tab draws itself.
/// The host calls `prepare` once per frame while the tab shows (a few pictures per call, so a long list never stalls a
/// frame), uploads `image` to `slot` when `generation` changed, and answers the tab's `picture` from `picture(for:)`.
@MainActor public final class TextTemplateTileAtlas {
    /// The draw list's slot for the tiles (`DrawList.imageSlots`: 0 thumbnails, 1 Slip two-up, 2-3 scopes).
    public static let slot = 4
    /// `TextTemplateTileView.pixelWidth` / `pixelHeight`.
    public static let cellWidth = 256, cellHeight = 160, columns = 8
    /// Pictures made per `prepare` call.
    public static let budget = 4

    /// Decodes a saved template's PNG (nil: no decoder on this platform, the look or the sample text shows).
    public var decodePicture: (@MainActor (Data) -> RGBAImage?)?
    /// The tile background (Mac `Theme.Colors.tileBackground`), sRGB bytes; a change redraws every picture.
    public var background: (UInt8, UInt8, UInt8) = (34, 34, 34) {
        didSet { if background != oldValue { cells = [:]; free = []; used = 0; generation += 1 } }
    }
    public private(set) var image = RGBAImage(width: TextTemplateTileAtlas.cellWidth * TextTemplateTileAtlas.columns, height: 0,
                                              pixels: [])
    /// Bumped on every change of `image`.
    public private(set) var generation = 0

    private struct Cell { var index: Int; var tile: TextTemplateTile; var drawn: Bool }
    private var cells: [String: Cell] = [:]
    private var free: [Int] = []
    private var used = 0

    public init() {}

    /// Makes up to `budget` missing pictures of `tiles` (in order), frees the cells of tiles no longer listed; true while
    /// some are still missing (the host draws another frame).
    @discardableResult
    public func prepare(_ tiles: [TextTemplateTile], budget: Int = TextTemplateTileAtlas.budget) -> Bool {
        let ids = Set(tiles.map(\.id))
        for (id, c) in cells where !ids.contains(id) { free.append(c.index); cells[id] = nil }
        var made = 0, left = false
        for tile in tiles where tile.thumbnail != nil || tile.style != nil {
            if let c = cells[tile.id], c.tile == tile { continue }
            guard made < budget else { left = true; break }
            made += 1
            let index = cells[tile.id]?.index ?? free.popLast() ?? { used += 1; return used - 1 }()
            let pixels = render(tile)
            if let pixels { blit(pixels, into: index) }
            cells[tile.id] = Cell(index: index, tile: tile, drawn: pixels != nil)
        }
        if made > 0 { generation += 1 }
        return left
    }

    /// The tile's picture, nil while it is not made (or has none).
    public func picture(for tile: TextTemplateTile) -> TextTemplateTilePicture? {
        guard let c = cells[tile.id], c.drawn, c.tile == tile, image.height > 0 else { return nil }
        let x = (c.index % Self.columns) * Self.cellWidth, y = (c.index / Self.columns) * Self.cellHeight
        let W = Float(image.width), H = Float(image.height)
        return TextTemplateTilePicture(slot: Self.slot, source: (Float(x) / W, Float(y) / H, Float(x + Self.cellWidth) / W,
                                                                  Float(y + Self.cellHeight) / H))
    }

    /// The tile's cell pixels: the saved PNG stretched to the cell (the Mac draws it into the well), else the look.
    private func render(_ tile: TextTemplateTile) -> [UInt8]? {
        let w = Self.cellWidth, h = Self.cellHeight
        if let data = tile.thumbnail, let img = decodePicture?(data), img.width > 0, img.height > 0 {
            return Self.resized(img, width: w, height: h, over: background)
        }
        guard let style = tile.style else { return nil }
        let bg = TextPresetStill.background(red: background.0, green: background.1, blue: background.2, width: w, height: h)
        return TextPresetStill.still(style: style, text: tile.sampleText, background: bg, width: w, height: h)
    }

    private func blit(_ px: [UInt8], into index: Int) {
        let cw = Self.cellWidth, ch = Self.cellHeight, rowBytes = image.width * 4
        let row = index / Self.columns, col = index % Self.columns
        var pixels = image.pixels
        let need = (row + 1) * ch * rowBytes
        if pixels.count < need { pixels.append(contentsOf: [UInt8](repeating: 0, count: need - pixels.count)) }
        for y in 0..<ch {
            let dst = (row * ch + y) * rowBytes + col * cw * 4
            pixels.replaceSubrange(dst..<(dst + cw * 4), with: px[(y * cw * 4)..<((y + 1) * cw * 4)])
        }
        image = RGBAImage(width: image.width, height: pixels.count / rowBytes, pixels: pixels)
    }

    /// `img` scaled to `width` x `height` (box average when shrinking, nearest when growing), over an opaque background.
    nonisolated static func resized(_ img: RGBAImage, width w: Int, height h: Int, over bg: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let sx = Double(img.width) / Double(w), sy = Double(img.height) / Double(h)
        let bgc = [bg.0, bg.1, bg.2]
        for y in 0..<h {
            let y0 = Int(Double(y) * sy), y1 = max(y0 + 1, min(img.height, Int(Double(y + 1) * sy)))
            for x in 0..<w {
                let x0 = Int(Double(x) * sx), x1 = max(x0 + 1, min(img.width, Int(Double(x + 1) * sx)))
                var sum = [0.0, 0.0, 0.0, 0.0]
                for yy in y0..<min(y1, img.height) {
                    for xx in x0..<min(x1, img.width) {
                        let i = (yy * img.width + xx) * 4
                        for k in 0..<4 { sum[k] += Double(img.pixels[i + k]) }
                    }
                }
                let n = Double(max(1, (min(y1, img.height) - y0) * (min(x1, img.width) - x0)))
                let a = sum[3] / n / 255, o = (y * w + x) * 4
                for k in 0..<3 { out[o + k] = UInt8(min(255, (sum[k] / n * a + Double(bgc[k]) * (1 - a)).rounded())) }
            }
        }
        return out
    }
}
