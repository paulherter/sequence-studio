import Foundation
import SQDrawKit
import SQText

/// Where an Effects grid tile's still sits in the atlas: the image slot and the normalized source rect.
public struct EffectsTilePicture: Equatable, Sendable {
    public var slot: Int
    public var x0: Float, y0: Float, x1: Float, y1: Float
    public var source: (Float, Float, Float, Float) { (x0, y0, x1, y1) }
}

/// The Effects grid's tile stills, packed into one image slot (`slot`): the Mac `EffectPreviewStore.buildStill` picture
/// at the same 192 x 108 pixels, i.e. a video transition mid-mix of the two procedural samples (`EffectPreviewPlan`), a
/// video effect applied to sample A, a text Look or Animation drawn by the real text renderer (`TextPresetStill`) on
/// sample A. Audio transitions and ids without a preview have no still (the grid draws their icon).
/// The host calls `prepare` once per frame with the visible tile ids (a few stills per call, so scrolling never stalls
/// a frame), uploads `image` to `slot` when `generation` changed, and answers the panel's `picture` from `picture(for:)`.
@MainActor public final class EffectsTileAtlas {
    /// The draw list's slot for the stills (`DrawList.imageSlots`: 4 the Text panel's template tiles).
    public static let slot = 5
    public nonisolated static let cellWidth = EffectPreviewPlan.sampleWidth, cellHeight = EffectPreviewPlan.sampleHeight, columns = 8
    /// Stills made per `prepare` call.
    public static let budget = 4

    public private(set) var image = RGBAImage(width: EffectsTileAtlas.cellWidth * EffectsTileAtlas.columns, height: 0, pixels: [])
    /// Bumped on every change of `image`.
    public private(set) var generation = 0

    private struct Cell { var index: Int; var drawn: Bool }
    private var cells: [String: Cell] = [:]
    /// Cell 0 is the live cell: the hovered tile's loop frame (the Mac `EffectsGridView` hover preview, 30 Hz).
    private var used = 1
    private var loops: [String: [[UInt8]]] = [:]
    private var loopsInFlight: Set<String> = []
    private var hover: (id: String, start: Double)?
    private var liveFrame = -1
    /// The tile whose loop is playing in the live cell (nil: none, or its loop is still being made).
    public private(set) var liveID: String?
    private nonisolated static let samples = EffectPreviewPlan.sampleImages(width: cellWidth, height: cellHeight)

    public init() {}

    /// Makes up to `budget` missing stills of `ids` (in order); true while some are still missing. Cells are kept for
    /// the session (as the Mac store's stills): the catalog is a few dozen tiles.
    @discardableResult
    public func prepare(_ ids: [String], budget: Int = EffectsTileAtlas.budget) -> Bool {
        var made = 0, left = false
        for id in ids where cells[id] == nil {
            guard made < budget else { left = true; break }
            made += 1
            guard let px = Self.still(id) else { cells[id] = Cell(index: -1, drawn: false); continue }
            let index = used
            used += 1
            blit(px, into: index)
            cells[id] = Cell(index: index, drawn: true)
        }
        if made > 0 { generation += 1 }
        return left
    }

    /// The pointer is over tile `id` (nil: none). The loop is made off the main thread on first use and cached.
    public func setHover(_ id: String?, now: Double) {
        guard id != hover?.id else { return }
        hover = id.map { ($0, now) }
        liveID = nil
        liveFrame = -1
        guard let id, loops[id] == nil, !loopsInFlight.contains(id) else { return }
        loopsInFlight.insert(id)
        Task.detached(priority: .utility) {
            let frames = Self.loop(id)
            await MainActor.run {
                self.loopsInFlight.remove(id)
                self.loops[id] = frames ?? []
            }
        }
    }

    /// Puts the hovered tile's loop frame for `now` into the live cell (a new frame bumps `generation`).
    public func advance(now: Double) {
        guard let h = hover, let loop = loops[h.id], !loop.isEmpty else { return }
        let f = Int(max(0, now - h.start) * EffectPreviewPlan.fps) % loop.count
        guard f != liveFrame || liveID != h.id else { return }
        liveFrame = f
        liveID = h.id
        blit(loop[f], into: 0)
        generation += 1
    }

    /// The tile's still, nil while it is not made (or the id has none); the live cell while its loop plays.
    public func picture(for id: String) -> EffectsTilePicture? {
        var index: Int
        if id == liveID { index = 0 } else {
            guard let c = cells[id], c.drawn else { return nil }
            index = c.index
        }
        guard image.height > 0 else { return nil }
        let x = (index % Self.columns) * Self.cellWidth, y = (index / Self.columns) * Self.cellHeight
        let W = Float(image.width), H = Float(image.height)
        return EffectsTilePicture(slot: Self.slot, x0: Float(x) / W, y0: Float(y) / H, x1: Float(x + Self.cellWidth) / W,
                                  y1: Float(y + Self.cellHeight) / H)
    }

    /// The still's opaque RGBA pixels (`EffectPreviewStore.buildStill`), nil for audio transitions and unknown ids.
    nonisolated static func still(_ id: String) -> [UInt8]? {
        let w = cellWidth, h = cellHeight
        switch EffectPreviewPlan.style(forID: id) {
        case .videoTransition(let k):
            return EffectPreviewPlan.blend(samples.a, samples.b, kind: k, weight: k == .crossDissolve ? 0.5 : 0.3)
        case .effect(let e):
            return EffectPreviewPlan.effectAfter(e, source: EffectPreviewPlan.effectBefore(e, sample: samples.a, width: w, height: h),
                                                 width: w, height: h)
        case .textPreset(let t):
            return TextPresetStill.still(t, background: samples.a, width: w, height: h)
        case .audioTransition, nil:
            return nil
        }
    }

    /// The loop frames of a video transition (hold, mix, hold) or an effect (before, after); nil for the rest (text
    /// presets: the Mac loop is drawn with CoreGraphics, they keep their still on Windows).
    nonisolated static func loop(_ id: String) -> [[UInt8]]? {
        let w = cellWidth, h = cellHeight
        switch EffectPreviewPlan.style(forID: id) {
        case .videoTransition(let k):
            var cache: [Double: [UInt8]] = [0: samples.a, 1: samples.b]
            return EffectPreviewPlan.transitionLoop.map { wgt in
                if let c = cache[wgt] { return c }
                let img = EffectPreviewPlan.blend(samples.a, samples.b, kind: k, weight: wgt)
                cache[wgt] = img
                return img
            }
        case .effect(let e):
            let before = EffectPreviewPlan.effectBefore(e, sample: samples.a, width: w, height: h)
            let half = Int(EffectPreviewPlan.fps * 0.9)
            return [[UInt8]](repeating: before, count: half) + [[UInt8]](repeating: EffectPreviewPlan.effectAfter(e, source: before, width: w, height: h), count: half)
        case .textPreset, .audioTransition, nil:
            return nil
        }
    }

    private func blit(_ px: [UInt8], into index: Int) {
        let cw = Self.cellWidth, ch = Self.cellHeight, rowBytes = image.width * 4
        guard px.count >= cw * ch * 4 else { return }
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
}
