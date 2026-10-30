import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQDrawKit
import SQText
import SQUIKit

/// The look gallery on the shared toolkit: `CaptionStyleLookGalleryView` and `LookSwatchView` translated. A heading per
/// group, then 92 × 74 tiles: the sample words in the look's style, still at rest, moving (entrance, loop, exit, lit
/// words) while the pointer is over a tile. The motion is `CaptionStyleLooks.pose` / `litWord`, the maths playback uses.
/// A click hands the look to `onPick`; the host decides where it lands (caption track or text clip).
/// shortcut: the sample is drawn with the UI face of the glyph atlas at the look's size and colors (fill, outline as
/// four offset copies, one shadow copy, the box), not with the look's own font: the atlas has one face. Use the text
/// renderer once the shell has a tile image slot.
/// Coordinates: points, y down, (0, 0) = the gallery's top-left.
@MainActor public final class LookGalleryDraw {
    public var theme = DrawTheme()
    public var width: CGFloat = 300
    public var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    public var onPick: (@MainActor (CaptionStyleLook) -> Void)?
    /// The look that matches what is applied now (accent outline); nil when nothing matches.
    public var currentID: String?
    public let groups: [LookGroup]

    private let library: CaptionPresetLibrary
    private let looks: [(group: LookGroup, looks: [CaptionStyleLook])]
    private(set) var hoverID: String?
    private var hoverStart = 0.0
    private var pressedID: String?

    public init(library: CaptionPresetLibrary = .builtIn, groups: [LookGroup] = LookGroup.allCases) {
        self.library = library
        self.groups = groups
        looks = groups.map { ($0, CaptionStyleLooks.looks(in: $0)) }
    }

    // MARK: Layout (CaptionStyleLookGalleryView.place)

    // shortcut: the Mac `Theme.Spacing.sm` (6) at UI scale 1; upgrade when SQUIKit's tokens move into a portable file.
    static let pad: CGFloat = 6
    static let gap: CGFloat = 6
    static let swatch = CGSize(width: 92, height: 74)
    static let headingHeight: CGFloat = 18
    static let words = ["Say", "it", "loud"]

    private func columns(_ w: CGFloat) -> Int { max(1, Int((w - 2 * Self.pad + Self.gap) / (Self.swatch.width + Self.gap))) }

    /// The height the grid needs at `width`.
    public func height(forWidth w: CGFloat) -> CGFloat { place(width: w).height }

    public var height: CGFloat { height(forWidth: width) }

    private func place(width w: CGFloat) -> (headings: [(LookGroup, CGFloat)], tiles: [(CaptionStyleLook, CGRect)], height: CGFloat) {
        let cols = columns(w), sw = Self.swatch, pad = Self.pad, gap = Self.gap
        var y = pad
        var headings: [(LookGroup, CGFloat)] = [], tiles: [(CaptionStyleLook, CGRect)] = []
        for (g, mine) in looks {
            headings.append((g, y))
            y += Self.headingHeight
            for (i, look) in mine.enumerated() {
                tiles.append((look, CGRect(x: pad + CGFloat(i % cols) * (sw.width + gap), y: y + CGFloat(i / cols) * (sw.height + gap),
                                           width: sw.width, height: sw.height)))
            }
            y += CGFloat((mine.count + cols - 1) / cols) * (sw.height + gap) + 4
        }
        return (headings, tiles, y + pad)
    }

    func frame(of id: String) -> CGRect? { place(width: width).tiles.first { $0.0.id == id }?.1 }

    func look(at p: CGPoint) -> CaptionStyleLook? { place(width: width).tiles.first { $0.1.contains(p) }?.0 }

    /// The still frame (`LookSwatchView.restTime`): settled after an entrance, mid-cycle in a loop, before an exit, one word lit.
    static func restTime(for group: LookGroup) -> Time {
        switch group {
        case .wordLight: Time(1, 1)
        case .entrance, .collection: Time(3, 2)
        case .motion: Time(1, 4)
        case .exit: .zero
        }
    }

    /// The preview time of `look`: its rest frame, or the looping preview window while it is hovered.
    func time(of look: CaptionStyleLook) -> Time {
        guard hoverID == look.id else { return Self.restTime(for: look.group) }
        let window = CaptionStyleLooks.previewDuration
        let ms = Int64(max(clock() - hoverStart, 0) * 1000)
        return Time(ms % max(window.value * 1000 / window.timescale, 1), 1000)
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme, laid = place(width: width)
        for (g, y) in laid.headings {
            c.draw(SQL10n.string(g.title), in: CGRect(x: Self.pad, y: y, width: max(width - 2 * Self.pad, 0), height: Self.headingHeight - 2),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2)
        }
        for (look, r) in laid.tiles { drawTile(&c, look, in: r) }
    }

    private func drawTile(_ c: inout Canvas, _ look: CaptionStyleLook, in r: CGRect) {
        let t = theme, current = look.id == currentID, radius = CGFloat(DrawTheme.Radius.control)
        let tile = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 16).insetBy(dx: 1, dy: 1)
        c.fill(roundedRect: tile, radius: radius, hoverID == look.id ? t.monitorBackdrop : t.content)
        c.saveGState()
        c.clip(to: tile)
        drawSample(&c, look, in: tile)
        c.restoreGState()
        c.stroke(roundedRect: tile, radius: radius, width: current ? 2 : 1, current ? t.accent : t.separator)
        c.draw(SQL10n.string(look.title), in: CGRect(x: r.minX - 4, y: r.maxY - 15, width: r.width + 8, height: 14),
               fontSize: CGFloat(DrawTheme.TypeSize.caption), current ? t.label : t.label2, align: .center)
    }

    /// `LookSwatchView.drawSample`: the words at 17 pt (sequence pixels to tile points), posed and lit at the tile's time.
    private func drawSample(_ c: inout Canvas, _ look: CaptionStyleLook, in tile: CGRect) {
        let style = library.style(for: look.styleRef)
        let k = 17.0 / max(style.size, 1)
        let at = time(of: look)
        let pose = CaptionStyleLooks.pose(of: look, library: library, at: at)
        let lit = look.karaoke.flatMap { _ in CaptionStyleLooks.litWord(count: Self.words.count, at: at) }
        let alpha = Float(min(max(pose.opacity, 0), 1))
        guard alpha > 0.001, pose.scale > 0.01 else { return }
        let fs = CGFloat(17 * pose.scale)
        func color(_ col: RGBAColor) -> DrawColor { DrawColor(Float(col.red), Float(col.green), Float(col.blue), Float(col.alpha) * alpha) }

        // The look's own font (bundled families; others draw in the UI face).
        let face = c.face(family: style.fontName, weight: style.weight, italic: style.italic)
        let space = c.size(of: " ", fontSize: fs, face: face).width
        let widths = Self.words.map { c.size(of: $0, fontSize: fs, face: face).width }
        let textW = widths.reduce(0, +) + space * CGFloat(Self.words.count - 1)
        let lineH = max(c.size(of: "Say", fontSize: fs, face: face).height, fs)
        let cx = tile.midX + CGFloat(pose.offsetX * k), cy = tile.midY + CGFloat(pose.offsetY * k)
        let s = CGFloat(pose.scale)
        if let bg = style.background {
            let pw = CGFloat(bg.padding.horizontal * k) * s, ph = CGFloat(bg.padding.vertical * k) * s
            let box = CGRect(x: cx - textW / 2 - pw, y: cy - lineH / 2 - ph, width: textW + 2 * pw, height: lineH + 2 * ph)
            c.fill(roundedRect: box, radius: min(CGFloat(bg.cornerRadius * k) * s, box.height / 2), color(bg.color))
        }
        func words(dx: CGFloat, dy: CGFloat, _ ink: (Int) -> DrawColor) {
            var x = cx - textW / 2 + dx
            for (i, w) in Self.words.enumerated() {
                c.draw(w, at: CGPoint(x: x, y: cy - lineH / 2 + dy), fontSize: fs, ink(i), face: face)
                x += widths[i] + space
            }
        }
        if let sh = style.shadow {
            words(dx: CGFloat(sh.offsetX * k) * s, dy: CGFloat(sh.offsetY * k) * s) { _ in color(sh.color) }
        }
        if let st = style.stroke, st.width > 0 {
            let d = max(CGFloat(min(st.width * k, 3)) * s, 0.75)
            for (dx, dy) in [(-d, 0), (d, 0), (0, -d), (0, d)] as [(CGFloat, CGFloat)] { words(dx: dx, dy: dy) { _ in color(st.color) } }
        }
        let base = color(style.color)
        words(dx: 0, dy: 0) { i in
            if let ks = look.karaoke, let lit, ks.keepSpoken ? i <= lit : i == lit { return color(CaptionKaraoke.color(ks)) }
            return base
        }
    }

    // MARK: Pointer

    /// Hover starts a tile's preview from its first frame (`LookSwatchView.mouseEntered`).
    public func mouseMoved(to p: CGPoint?) {
        let id = p.flatMap(look(at:))?.id
        guard id != hoverID else { return }
        hoverID = id
        hoverStart = clock()
    }

    public func mouseDown(at p: CGPoint) { pressedID = look(at: p)?.id }

    /// A release over the pressed tile picks its look.
    public func mouseUp(at p: CGPoint) {
        defer { pressedID = nil }
        guard let id = pressedID, let l = look(at: p), l.id == id else { return }
        onPick?(l)
    }

    /// True while a tile is previewing (the host redraws at display rate); no animation runs otherwise.
    public func tick() -> Bool { hoverID != nil }

    public func help(at p: CGPoint) -> String? { look(at: p).map { SQL10n.string($0.title) } }
}
