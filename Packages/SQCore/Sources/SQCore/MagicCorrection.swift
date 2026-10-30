import Foundation

// Magic mask corrections: add / remove points that cut a picked object apart or grow it where the segmentation has no
// object (Vision merged the person with a lamp, or missed a hat). Works on a coarse grid (at most `gridMax` px a side) of
// the frame's picture (`MagicGuide`): a color-aware geodesic distance from the points decides which pixels belong to the
// correction, so cuts and growth follow color edges. The regions found are carried to the next frame (`MagicCorrection
// .State`), so one correction keeps working while the shot is tracked.

public enum MagicCorrection {
    /// Longest side of the work grid.
    public static let gridMax = 160
    /// How far a correction reaches from its points: color steps plus distance (a uniform area reaches ~30 % of the frame).
    public static let reach: Float = 0.35
    /// Color differences below this (RGB distance 0...1.7) are texture, not an edge.
    public static let colorFloor: Float = 0.03
    /// How far (grid cells) a carried region is searched for on the next frame.
    public static let searchRadius = 8
    /// A carried cell survives when its color moved along with it (RGB distance).
    public static let carryColor: Float = 0.15

    /// The coarse picture and the selection mask on the grid.
    public struct Grid: Sendable {
        public let width: Int
        public let height: Int
        var rgb: [Float]
        /// Spatial cost of one grid step (so a uniform area is reached up to ~30 % of the frame).
        var step: Float { reach / (0.3 * Float(max(width, height))) }

        public init(guide g: MagicGuide) {
            let s = min(1, Double(MagicCorrection.gridMax) / Double(max(g.width, g.height)))
            let w = max(1, Int((Double(g.width) * s).rounded())), h = max(1, Int((Double(g.height) * s).rounded()))
            width = w; height = h
            var out = [Float](repeating: 0, count: w * h * 3)
            var count = [Float](repeating: 0, count: w * h)
            for y in 0..<g.height {
                let gy = min(y * h / g.height, h - 1)
                for x in 0..<g.width {
                    let gx = min(x * w / g.width, w - 1)
                    let i = gy * w + gx, j = (y * g.width + x) * 3
                    out[i * 3] += g.rgb[j]; out[i * 3 + 1] += g.rgb[j + 1]; out[i * 3 + 2] += g.rgb[j + 2]
                    count[i] += 1
                }
            }
            for i in 0..<(w * h) where count[i] > 0 {
                out[i * 3] /= count[i]; out[i * 3 + 1] /= count[i]; out[i * 3 + 2] /= count[i]
            }
            rgb = out
        }

        /// Grid cell of frame fraction `p` (clamped).
        func cell(_ p: Vec2) -> Int {
            let x = min(max(Int(p.x * Double(width)), 0), width - 1), y = min(max(Int(p.y * Double(height)), 0), height - 1)
            return y * width + x
        }

        /// A matte of any size on the grid (area mean), as inside / outside at 0.5.
        func inside(_ m: SubjectMatte) -> [Bool] {
            let r = m.resampled(width: width, height: height)
            return r.values.map { $0 >= 0.5 }
        }

        /// Color-aware geodesic distance from `seeds` over the cells `allowed` permits (infinity elsewhere).
        func distances(from seeds: [Int], allowed: [Bool]) -> [Float] {
            var d = [Float](repeating: .infinity, count: width * height)
            var heap = MinHeap()
            for s in seeds where allowed[s] && d[s] > 0 { d[s] = 0; heap.push(0, s) }
            let st = step, diag = step * Float(2).squareRoot()
            while let (c, i) = heap.pop() {
                guard c <= d[i] else { continue }
                let x = i % width, y = i / width
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let j = ny * width + nx
                        guard allowed[j] else { continue }
                        let a = i * 3, b = j * 3
                        let dr = rgb[a] - rgb[b], dg = rgb[a + 1] - rgb[b + 1], db = rgb[a + 2] - rgb[b + 2]
                        let col = max((dr * dr + dg * dg + db * db).squareRoot() - colorFloor, 0)
                        let nc = c + col + (dx != 0 && dy != 0 ? diag : st)
                        if nc < d[j] { d[j] = nc; heap.push(nc, j) }
                    }
                }
            }
            return d
        }

        /// Cells of `m` minus a border of `r` cells (seeds that stay clear of the edge).
        func eroded(_ m: [Bool], _ r: Int) -> [Bool] {
            guard r > 0 else { return m }
            var out = m
            for y in 0..<height { for x in 0..<width where m[y * width + x] {
                outer: for dy in -r...r { for dx in -r...r {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= width || ny >= height || !m[ny * width + nx] { out[y * width + x] = false; break outer }
                } }
            } }
            return out
        }

        func dilated(_ m: [Bool], _ r: Int) -> [Bool] { eroded(m.map { !$0 }, r).map { !$0 } }

        /// A grid mask as a matte of `w` x `h` (bilinear: soft edges at the grid's resolution).
        func matte(_ m: [Bool], width w: Int, height h: Int) -> SubjectMatte {
            SubjectMatte(width: width, height: height, values: m.map { $0 ? 1 : 0 }).resampled(width: w, height: h)
        }

        /// `region` of the last frame's picture `before` (same grid) carried onto this frame: moved by the shift (up to
        /// `searchRadius` cells) whose colors match best, then only the cells whose color still matches.
        func carry(_ region: [Bool], from before: [Float]) -> [Bool] {
            let cells = region.indices.filter { region[$0] }
            guard !cells.isEmpty, before.count == rgb.count else { return [Bool](repeating: false, count: region.count) }
            let sample = cells.count > 600 ? stride(from: 0, to: cells.count, by: cells.count / 600).map { cells[$0] } : cells
            func diff(_ i: Int, _ j: Int) -> Float {
                let a = i * 3, b = j * 3
                let dr = before[a] - rgb[b], dg = before[a + 1] - rgb[b + 1], db = before[a + 2] - rgb[b + 2]
                return (dr * dr + dg * dg + db * db).squareRoot()
            }
            let r = MagicCorrection.searchRadius
            var best = (0, 0), bestCost = Float.infinity
            for dy in -r...r { for dx in -r...r {
                var c: Float = 0
                for i in sample {
                    let x = i % width + dx, y = i / width + dy
                    c += x < 0 || y < 0 || x >= width || y >= height ? 1 : diff(i, y * width + x)
                }
                // Ties go to the smaller move.
                c += Float(abs(dx) + abs(dy)) * 1e-4 * Float(sample.count)
                if c < bestCost { bestCost = c; best = (dx, dy) }
            } }
            var out = [Bool](repeating: false, count: region.count)
            for i in cells {
                let x = i % width + best.0, y = i / width + best.1
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let j = y * width + x
                if diff(i, j) < MagicCorrection.carryColor { out[j] = true }
            }
            return out
        }
    }

    /// Regions a correction found on the last frame, carried to the next one (grid cells).
    public struct State: Sendable {
        var width = 0, height = 0
        var removed: [Bool] = []
        var added: [Bool] = []
        var kept: [Bool] = []
        /// The last frame's grid picture (carried regions are found again on the next frame by color).
        var rgb: [Float] = []
        public var isEmpty: Bool { !removed.contains(true) && !added.contains(true) }
        public init() {}
    }

    /// Applies the corrections of this frame (`add` / `remove`: frame fractions of the points made on it) and the carried
    /// regions of `state` to `base` (the soft matte of the followed objects). Returns the corrected matte; updates `state`.
    /// Without a guide, or with nothing to correct, `base` comes back unchanged.
    ///
    /// Cut: the selection splits between remove seeds (this frame's remove points, last frame's removed region) and keep
    /// seeds (add points, last frame's kept core, and every selected cell beyond `reach` of the remove seeds); a cell goes
    /// to the nearer side, so the split lands on the color edge between them. Grow works the same way outside the selection.
    public static func apply(base: SubjectMatte, guide: MagicGuide?, add: [Vec2], remove: [Vec2],
                             state: inout State) -> SubjectMatte {
        guard let guide else { return base }
        guard !add.isEmpty || !remove.isEmpty || !state.isEmpty else { state.kept = []; return base }
        let g = Grid(guide: guide)
        if state.width != g.width || state.height != g.height {
            state = State(); state.width = g.width; state.height = g.height
        }
        let n = g.width * g.height
        let none = [Bool](repeating: false, count: n)
        let inBase = g.inside(base)
        let removedBefore = state.removed.contains(true) ? g.carry(g.eroded(state.removed, 1), from: state.rgb) : none
        let keptBefore = state.kept.contains(true) ? g.carry(g.eroded(state.kept, 1), from: state.rgb) : none
        let addedBefore = state.added.contains(true) ? g.carry(g.eroded(state.added, 1), from: state.rgb) : none
        let removeCells = remove.map(g.cell)
        let addCells = add.map(g.cell)

        var cut = none
        var removeSeeds = removeCells.filter { inBase[$0] }
        for i in 0..<n where removedBefore[i] && inBase[i] { removeSeeds.append(i) }
        if !removeSeeds.isEmpty {
            let dRemove = g.distances(from: removeSeeds, allowed: inBase)
            // A fresh remove point overrules what was kept on the last frame.
            let carryKept = !removeCells.contains { inBase[$0] }
            var keepSeeds = addCells.filter { inBase[$0] && dRemove[$0] > 0 }
            for i in 0..<n where inBase[i] && dRemove[i] > 0 && ((carryKept && keptBefore[i]) || dRemove[i] >= reach) { keepSeeds.append(i) }
            let dKeep = g.distances(from: keepSeeds, allowed: inBase)
            for i in 0..<n where inBase[i] { cut[i] = dRemove[i] < dKeep[i] }
        }

        var grow = none
        let outside = inBase.map { !$0 }
        var addSeeds = addCells.filter { outside[$0] }
        for i in 0..<n where addedBefore[i] && outside[i] { addSeeds.append(i) }
        if !addSeeds.isEmpty {
            let dAdd = g.distances(from: addSeeds, allowed: outside)
            var stopSeeds = removeCells.filter { outside[$0] && dAdd[$0] > 0 }
            for i in 0..<n where outside[i] && dAdd[i] > 0 && dAdd[i] >= reach { stopSeeds.append(i) }
            let dStop = g.distances(from: stopSeeds, allowed: outside)
            for i in 0..<n where outside[i] { grow[i] = dAdd[i] < dStop[i] }
        }

        state.removed = cut
        state.added = grow
        state.kept = (0..<n).map { inBase[$0] && !cut[$0] }
        state.rgb = g.rgb
        guard cut.contains(true) || grow.contains(true) else { return base }
        let cutM = g.matte(cut, width: base.width, height: base.height)
        let growM = g.matte(grow, width: base.width, height: base.height)
        var v = base.values
        for i in 0..<v.count { v[i] = max(v[i] * (1 - cutM.values[i]), growM.values[i]) }
        return SubjectMatte(width: base.width, height: base.height, values: v)
    }

    /// The correction a stored matte already holds (`corrected` against the segmentation's `raw` matte of the same
    /// objects), as carried state: Track that continues from a corrected frame keeps the correction.
    public static func state(raw: SubjectMatte, corrected: SubjectMatte, guide: MagicGuide?) -> State {
        guard let guide else { return State() }
        let g = Grid(guide: guide)
        let a = g.inside(raw), b = g.inside(corrected)
        var s = State()
        s.width = g.width; s.height = g.height
        s.removed = zip(a, b).map { $0 && !$1 }
        s.added = zip(a, b).map { !$0 && $1 }
        // Specks from soft edges are no correction.
        s.removed = g.dilated(g.eroded(s.removed, 1), 1)
        s.added = g.dilated(g.eroded(s.added, 1), 1)
        s.kept = zip(a, s.removed).map { $0 && !$1 }
        s.rgb = g.rgb
        return s
    }
}

/// Binary min-heap of (cost, cell) for the geodesic distance.
struct MinHeap {
    private var items: [(Float, Int)] = []
    mutating func push(_ c: Float, _ i: Int) {
        items.append((c, i))
        var k = items.count - 1
        while k > 0 {
            let p = (k - 1) / 2
            guard items[p].0 > items[k].0 else { break }
            items.swapAt(p, k); k = p
        }
    }
    mutating func pop() -> (Float, Int)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var k = 0
            while true {
                let l = 2 * k + 1, r = l + 1
                var m = k
                if l < items.count, items[l].0 < items[m].0 { m = l }
                if r < items.count, items[r].0 < items[m].0 { m = r }
                if m == k { break }
                items.swapAt(m, k); k = m
            }
        }
        return top
    }
}
