import Accelerate
import Foundation
import SQCore

/// The inside of a mask is solid: soft alpha only in a thin band at its edge. The edge steps lower alpha up to 20 px
/// inside the model's mask (their window), where a part that has the background's color (gaps between hair strands, a
/// white phone before a bright wall) turned see-through, and the system's segmentation gives a picked object 0.6-0.9.
/// Every matte of a leg (after its edge step) and every pick of the system's segmentation goes through `solid`.
enum SubjectMatteCore {
    /// Width of the band (pixels of a matte `width` x `height`): one cell of the model's logit grid, which is as
    /// close as the model places an edge; at least 2.
    static func band(width: Int, height: Int) -> Int {
        max(2, Int((Double(max(width, height)) / Double(SubjectTrackRules.logitSize)).rounded()))
    }

    /// `matte` with alpha 1 wherever `mask` (any size; the matte before its edge step) is at least 0.5 within
    /// `band` px around. `mask` nil: the matte's own 0.5 contour.
    static func solid(_ matte: SubjectMatte, mask: SubjectMatte? = nil) -> SubjectMatte {
        let src = mask ?? matte
        let w = src.width, h = src.height, n = w * h
        guard n > 0, matte.width > 0, matte.height > 0 else { return matte }
        let r = band(width: w, height: h)
        // In or out (255 / 0) at the mask's size, then eroded by the band.
        var bin = [UInt8](repeating: 0, count: n), core = bin
        let ok = src.values.withUnsafeBytes { s in bin.withUnsafeMutableBytes { b in core.withUnsafeMutableBytes { c -> Bool in
            var fs = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var bb = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            var cb = vImage_Buffer(data: c.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            guard vImageConvert_PlanarFtoPlanar8(&fs, &bb, 0.5, 0.4999, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            let side = vImagePixelCount(2 * r + 1)
            return vImageMin_Planar8(&bb, &cb, nil, 0, 0, side, side, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        } } }
        guard ok else { return matte }
        // At the matte's size (the Quality step works at its own size).
        let mw = matte.width, mh = matte.height
        if mw != w || mh != h {
            var scaled = [UInt8](repeating: 0, count: mw * mh)
            let done = core.withUnsafeMutableBytes { c in scaled.withUnsafeMutableBytes { d -> Bool in
                var cb = vImage_Buffer(data: c.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(mh), width: vImagePixelCount(mw), rowBytes: mw)
                return vImageScale_Planar8(&cb, &db, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            } }
            guard done else { return matte }
            core = scaled
        }
        var solid = [Float](repeating: 0, count: mw * mh)
        vDSP.convertElements(of: core, to: &solid)
        vDSP.multiply(1 / Float(255), solid, result: &solid)
        vDSP.maximum(solid, matte.values, result: &solid)
        return SubjectMatte(width: mw, height: mh, values: solid)
    }
}
