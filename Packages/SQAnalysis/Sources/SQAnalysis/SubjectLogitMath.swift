import Foundation
import SQCore

/// `SubjectTrackRules.stats` and `SubjectCropPass.constrain` for the per-frame path: the same loops, in this target,
/// which is optimized in a Debug build (SQCore is not; there the two took ~15 ms of every tracked frame). SQCore's
/// versions stay the reference (`SubjectLogitMathTests`).
enum SubjectLogitMath {
    static func stats(logits: [Float], size: Int) -> (area: Double, box: SubjectTrackBox?) {
        precondition(logits.count >= size * size, "logits size mismatch")
        var n = 0, minX = size, minY = size, maxX = -1, maxY = -1
        logits.withUnsafeBufferPointer { p in
            for y in 0..<size {
                let row = y * size
                var rowN = 0, first = size, last = -1
                for x in 0..<size where p[row + x] > 0 {
                    rowN += 1
                    if first == size { first = x }
                    last = x
                }
                guard rowN > 0 else { continue }
                n += rowN
                minX = min(minX, first); maxX = max(maxX, last)
                if minY == size { minY = y }
                maxY = y
            }
        }
        guard n > 0 else { return (0, nil) }
        let s = Double(size)
        return (Double(n) / (s * s), SubjectTrackBox(x0: Double(minX) / s, y0: Double(minY) / s, x1: Double(maxX + 1) / s, y1: Double(maxY + 1) / s))
    }

    static func constrain(_ logits: [Float], size: Int, to band: SubjectTrackBox) -> [Float] {
        let outside = -SubjectTrackRules.matteLogit
        // Which columns lie inside the band, once (the same test per pixel as the reference).
        var columns = [Bool](repeating: false, count: size)
        for x in 0..<size {
            let u = (Double(x) + 0.5) / Double(size)
            columns[x] = u >= band.x0 && u <= band.x1
        }
        var out = logits
        out.withUnsafeMutableBufferPointer { o in
            columns.withUnsafeBufferPointer { c in
                for y in 0..<size {
                    let v = (Double(y) + 0.5) / Double(size)
                    let row = y * size
                    if !(v >= band.y0 && v <= band.y1) {
                        for x in 0..<size { o[row + x] = outside }
                        continue
                    }
                    for x in 0..<size where !c[x] { o[row + x] = outside }
                }
            }
        }
        return out
    }
}
