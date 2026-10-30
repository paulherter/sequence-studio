import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQText
import SQUIKit
import SQLibrary
import SQEditorSession

/// Effects panel layout mode, persisted like the Project and Library panels (own defaults key).
public enum EffectsViewMode: String, Sendable {
    case list, grid
    public static let key = "EffectsPanel.viewMode"
    public static func load(from d: UserDefaults = .standard) -> EffectsViewMode { EffectsViewMode(rawValue: d.string(forKey: key) ?? "") ?? .list }
    public func save(to d: UserDefaults = .standard) { d.set(rawValue, forKey: Self.key) }
}

/// Pure logic behind the Effects grid thumbnails and hover previews. Everything is RGBA8 bytes (alpha 255), made in code
/// (no licensed media). Transitions are mixed with `TransitionMix`, the same maths as the render path, so the preview
/// shows what the compositor will do; the work is a few hundred bytes-blends at thumbnail size, done once and cached.
public enum EffectPreviewPlan {
    public static let fps = 30.0
    /// One second at `fps`: hold A, mix, hold B.
    public static let loopFrames = 30
    public static let holdFrames = 4
    public static let mixFrames = loopFrames - 2 * holdFrames
    /// Thumbnail raster (16:9; drawn at 2x for a ~96 pt tile).
    public static let sampleWidth = 192, sampleHeight = 108

    /// Incoming weight (0 = A only, 1 = B only) per loop frame.
    public static var transitionLoop: [Double] {
        [Double](repeating: 0, count: holdFrames)
            + (0..<mixFrames).map { TransitionMix.videoWeight(frameIndex: $0, frames: mixFrames) }
            + [Double](repeating: 1, count: holdFrames)
    }

    public enum Style: Sendable, Equatable {
        case videoTransition(TransitionKind)
        case audioTransition(TransitionKind)
        case effect(String)
        /// A text Look or Animation (`TextPresetCatalog` id): drawn by the real text renderer.
        case textPreset(String)
    }

    public static func style(forID id: String) -> Style? {
        if TextPresetCatalog.isTextPresetID(id) { return .textPreset(id) }
        let prefix = "transition."
        if id.hasPrefix(prefix), let k = TransitionKind(rawValue: String(id.dropFirst(prefix.count))) { return k.trackKind == .video ? .videoTransition(k) : .audioTransition(k) }
        return EffectCatalog.spec(for: id) != nil ? .effect(id) : nil
    }

    // MARK: Mixing

    /// Blends two RGBA buffers with the render path's mix at incoming weight `w`.
    public static func blend(_ a: [UInt8], _ b: [UInt8], kind: TransitionKind, weight w: Double) -> [UInt8] {
        let m = TransitionMix.video(kind, weight: w)
        let dip = TransitionMix.dipColor(kind)
        let o = m.outgoing, inc = m.incoming
        let d = (m.dip * Double(dip[0]), m.dip * Double(dip[1]), m.dip * Double(dip[2]))
        var out = a
        out.withUnsafeMutableBufferPointer { op in
            a.withUnsafeBufferPointer { ap in
                b.withUnsafeBufferPointer { bp in
                    var i = 0
                    let n = ap.count
                    while i < n {
                        let r = o * Double(ap[i]) + inc * Double(bp[i]) + d.0
                        let g = o * Double(ap[i + 1]) + inc * Double(bp[i + 1]) + d.1
                        let bl = o * Double(ap[i + 2]) + inc * Double(bp[i + 2]) + d.2
                        op[i] = UInt8(min(max(r.rounded(), 0), 255))
                        op[i + 1] = UInt8(min(max(g.rounded(), 0), 255))
                        op[i + 2] = UInt8(min(max(bl.rounded(), 0), 255))
                        i += 4
                    }
                }
            }
        }
        return out
    }

    // MARK: Sample images

    /// Two clearly different landscapes: a warm sunset over dark ridges (A) and a cool green valley under a pale sky (B).
    public static func sampleImages(width w: Int, height h: Int) -> (a: [UInt8], b: [UInt8]) {
        var a = [UInt8](repeating: 255, count: w * h * 4), b = a
        func put(_ buf: inout [UInt8], _ x: Int, _ y: Int, _ r: Double, _ g: Double, _ bl: Double) {
            let i = (y * w + x) * 4
            buf[i] = UInt8(min(max(r, 0), 255)); buf[i + 1] = UInt8(min(max(g, 0), 255)); buf[i + 2] = UInt8(min(max(bl, 0), 255))
        }
        for y in 0..<h {
            let t = Double(y) / Double(h - 1)
            for x in 0..<w {
                let u = Double(x) / Double(w - 1)
                // A: sky from deep blue to orange, sun, two ridges.
                var r = 40 + 215 * t, g = 60 + 120 * t * t, bl = 140 - 90 * t
                let dx = (u - 0.68) * Double(w), dy = (t - 0.62) * Double(h)
                let sun = max(0, 1 - (dx * dx + dy * dy).squareRoot() / (0.16 * Double(h)))
                r += 200 * sun; g += 170 * sun; bl += 60 * sun
                let ridge1 = 0.74 + 0.08 * sin(u * 9) + 0.04 * sin(u * 23 + 1)
                let ridge2 = 0.86 + 0.05 * sin(u * 6 + 2)
                if t > ridge2 { r = 18; g = 20; bl = 30 } else if t > ridge1 { r = 52; g = 40; bl = 60 }
                put(&a, x, y, r, g, bl)
                // B: pale cyan sky, rolling green hills, a lake.
                var r2 = 150 + 70 * (1 - t), g2 = 200 + 40 * (1 - t), b2 = 235 - 30 * t
                let hill1 = 0.55 + 0.10 * sin(u * 5 + 0.5) + 0.03 * sin(u * 17)
                let hill2 = 0.70 + 0.07 * sin(u * 7 + 3)
                if t > 0.9 { r2 = 40; g2 = 110; b2 = 150 }
                else if t > hill2 { r2 = 40; g2 = 120 + 40 * u; b2 = 60 }
                else if t > hill1 { r2 = 90; g2 = 150; b2 = 90 }
                put(&b, x, y, r2, g2, b2)
            }
        }
        return (a, b)
    }

    // MARK: Effect before/after

    /// "After" image for a video effect applied to `src` (the "before" is `src` itself). Same ideas as the render blocks,
    /// simplified to the thumbnail size.
    public static func effectAfter(_ id: String, source src: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        switch id {
        case ClipEffect.gaussianBlurKind:
            return boxBlur(src, w, h, radius: 4, passes: 3)
        case ClipEffect.cropKind:
            var out = src
            let mx = w / 6, my = h / 6
            for y in 0..<h { for x in 0..<w where x < mx || x >= w - mx || y < my || y >= h - my {
                let i = (y * w + x) * 4; out[i] = 0; out[i + 1] = 0; out[i + 2] = 0
            } }
            return out
        case ClipEffect.roundedCornersKind:
            var out = src
            let r = Double(min(w, h)) * 0.28
            for y in 0..<h { for x in 0..<w {
                let cx = min(max(Double(x) + 0.5, r), Double(w) - r), cy = min(max(Double(y) + 0.5, r), Double(h) - r)
                let d = ((Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy)).squareRoot()
                if d > r { let i = (y * w + x) * 4; out[i] = 0; out[i + 1] = 0; out[i + 2] = 0 }
            } }
            return out
        case ClipEffect.ultraKeyKind:
            var out = src
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4
                if keyIsGreen(src[i], src[i + 1], src[i + 2]) {
                    let on = ((x / 8) + (y / 8)) % 2 == 0
                    let v: UInt8 = on ? 90 : 55
                    out[i] = v; out[i + 1] = v; out[i + 2] = v
                }
            } }
            return out
        default:
            return src
        }
    }

    /// "Before" image for an effect: the sample, except Ultra Key which needs a green backdrop to key.
    public static func effectBefore(_ id: String, sample src: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        guard id == ClipEffect.ultraKeyKind else { return src }
        var out = src
        for y in 0..<h { for x in 0..<w {
            let dx = (Double(x) / Double(w) - 0.5) * 16, dy = (Double(y) / Double(h) - 0.55) * 9
            let i = (y * w + x) * 4
            if dx * dx + dy * dy > 6.5 { out[i] = 20; out[i + 1] = 200; out[i + 2] = 60 }   // green screen around the subject
        } }
        return out
    }

    public static func keyIsGreen(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { Int(g) > Int(r) + 60 && Int(g) > Int(b) + 60 }

    public static func boxBlur(_ src: [UInt8], _ w: Int, _ h: Int, radius: Int, passes: Int) -> [UInt8] {
        var cur = src, tmp = src
        for _ in 0..<passes {
            for y in 0..<h {                                    // horizontal
                for c in 0..<3 {
                    var sum = 0
                    for x in -radius...radius { sum += Int(cur[(y * w + min(max(x, 0), w - 1)) * 4 + c]) }
                    for x in 0..<w {
                        tmp[(y * w + x) * 4 + c] = UInt8(sum / (2 * radius + 1))
                        let add = min(x + radius + 1, w - 1), sub = max(x - radius, 0)
                        sum += Int(cur[(y * w + add) * 4 + c]) - Int(cur[(y * w + sub) * 4 + c])
                    }
                }
            }
            for x in 0..<w {                                    // vertical
                for c in 0..<3 {
                    var sum = 0
                    for y in -radius...radius { sum += Int(tmp[(min(max(y, 0), h - 1) * w + x) * 4 + c]) }
                    for y in 0..<h {
                        cur[(y * w + x) * 4 + c] = UInt8(sum / (2 * radius + 1))
                        let add = min(y + radius + 1, h - 1), sub = max(y - radius, 0)
                        sum += Int(tmp[(add * w + x) * 4 + c]) - Int(tmp[(sub * w + x) * 4 + c])
                    }
                }
            }
        }
        return cur
    }
}

/// Tile layout of the Effects grid: category headers span the width, tiles flow left to right under them.
public struct EffectsGridLayout: Sendable {
    public struct Item: Sendable, Equatable {
        public var id: String, title: String, symbol: SQIcon
        public var isHeader: Bool
        public var frame: CGRect
        /// The thumbnail inside a tile (16:9); empty for headers.
        public var thumb: CGRect
    }
    public static let pad: CGFloat = 8, gap: CGFloat = 8, headerHeight: CGFloat = 24, captionHeight: CGFloat = 18

    public private(set) var items: [Item] = []
    public private(set) var columns = 1
    public private(set) var contentHeight: CGFloat = 0

    public init(rows: [EffectsRow], width: CGFloat, tileWidth: CGFloat) {
        let pad = Self.pad, gap = Self.gap
        columns = max(1, Int((width - 2 * pad + gap) / (tileWidth + gap)))
        let thumbH = (tileWidth * 9 / 16).rounded()
        let tileH = thumbH + Self.captionHeight
        var y: CGFloat = 4, col = 0
        for r in rows {
            if r.isHeader {
                if col > 0 { y += tileH + gap; col = 0 }
                items.append(Item(id: r.id, title: r.title, symbol: r.symbol, isHeader: true,
                                  frame: CGRect(x: 0, y: y, width: width, height: Self.headerHeight), thumb: .zero))
                y += Self.headerHeight
                continue
            }
            let x = pad + CGFloat(col) * (tileWidth + gap)
            items.append(Item(id: r.id, title: r.title, symbol: r.symbol, isHeader: false,
                              frame: CGRect(x: x, y: y, width: tileWidth, height: tileH),
                              thumb: CGRect(x: x, y: y, width: tileWidth, height: thumbH)))
            col += 1
            if col == columns { y += tileH + gap; col = 0 }
        }
        if col > 0 { y += tileH + gap }
        contentHeight = y + 4
    }

    /// The tile under `p` (headers are not targets).
    public func hit(_ p: CGPoint) -> String? { items.first { !$0.isHeader && $0.frame.contains(p) }?.id }
}
