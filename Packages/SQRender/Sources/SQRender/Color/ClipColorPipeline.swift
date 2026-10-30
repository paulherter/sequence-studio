import Foundation
import SQCore

extension SourceColorSpace {
    public init(_ id: ColorSpaceID) {
        switch id {
        case .rec709: self = .rec709
        case .sLog3SGamut3Cine: self = .sLog3SGamut3Cine
        case .hlgBT2020: self = .hlgBT2020
        case .pqBT2020: self = .pqBT2020
        case .vLogVGamut: self = .vLogVGamut
        case .appleLog: self = .appleLog
        case .dLogDGamut: self = .dLogDGamut
        case .canonLogCinemaGamut: self = .canonLogCinemaGamut
        case .canonLogBT2020: self = .canonLogBT2020
        case .canonLogBT709: self = .canonLogBT709
        case .canonLog2CinemaGamut: self = .canonLog2CinemaGamut
        case .canonLog2BT2020: self = .canonLog2BT2020
        case .canonLog2BT709: self = .canonLog2BT709
        case .canonLog3CinemaGamut: self = .canonLog3CinemaGamut
        case .canonLog3BT2020: self = .canonLog3BT2020
        case .canonLog3BT709: self = .canonLog3BT709
        case .logC3WideGamut3: self = .logC3WideGamut3
        case .logC4WideGamut4: self = .logC4WideGamut4
        case .log3G10RedWideGamut: self = .log3G10RedWideGamut
        case .bmdFilmGen5WideGamut: self = .bmdFilmGen5WideGamut
        case .nLogBT2020: self = .nLogBT2020
        case .fLog2FGamutC: self = .fLog2FGamutC
        case .acesCCTAP1: self = .acesCCTAP1
        }
    }
}

/// Loads parsed LUTs for a reference. Only `.file` and `.embedded` are loadable; `.automatic` yields nil.
public protocol LUTProvider: Sendable {
    func lut(for ref: LUTRef) -> CubeLUT?
    /// Identity of the LUT's file contents (modification date + size) so edits on disk are noticed. nil = not file-backed.
    func stamp(for ref: LUTRef) -> LUTStamp?
}

public extension LUTProvider {
    func stamp(for ref: LUTRef) -> LUTStamp? { nil }
}

public struct LUTStamp: Sendable, Hashable {
    public var modified: Date?
    public var size: Int
    public init(modified: Date?, size: Int) { self.modified = modified; self.size = size }

    public static func ofFile(_ path: String) -> LUTStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return LUTStamp(modified: a[.modificationDate] as? Date, size: (a[.size] as? Int) ?? 0)
    }
}

/// Parses each referenced LUT once (successes only; failed loads are retried) and serves it from memory afterwards.
/// The loaders return raw `.cube` bytes: a file read for `.file`, and for `.embedded` the app layer's glue over
/// SQMedia `EmbeddedMeta.lut(inClip:)` (media ID -> file -> `EmbeddedLUT.data`).
public final class CachingLUTProvider: LUTProvider, @unchecked Sendable {
    public typealias FileLoader = @Sendable (String) -> Data?
    public typealias EmbeddedLoader = @Sendable (UUID) -> Data?
    public typealias StampReader = @Sendable (String) -> LUTStamp?

    private let lock = NSLock()
    private var cache: [LUTRef: (stamp: LUTStamp?, lut: CubeLUT)] = [:]
    private let stampReader: StampReader
    private let fileLoader: FileLoader
    private let embeddedLoader: EmbeddedLoader

    public init(file: @escaping FileLoader = { FileManager.default.contents(atPath: $0) },
                embedded: @escaping EmbeddedLoader,
                stamp: @escaping StampReader = { LUTStamp.ofFile($0) }) {
        fileLoader = file; embeddedLoader = embedded; stampReader = stamp
    }

    public func stamp(for ref: LUTRef) -> LUTStamp? {
        if case .file(let path) = ref { return stampReader(path) }
        return nil
    }

    public func lut(for ref: LUTRef) -> CubeLUT? {
        let data: Data?
        let stamp = self.stamp(for: ref)
        switch ref {
        case .automatic: return nil
        case .file(let path):
            if let hit = cached(ref, stamp: stamp) { return hit }
            data = fileLoader(path)
        case .embedded(let id):
            if let hit = cached(ref, stamp: nil) { return hit }
            data = embeddedLoader(id)
        }
        // I/O and parsing happen outside the lock; failures are not cached (the file may appear or be fixed later).
        guard let lut = data.flatMap({ try? CubeLUT.parse(String(decoding: $0, as: UTF8.self)) }) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let existing = cache[ref], existing.stamp == stamp { return existing.lut }
        cache[ref] = (stamp, lut)
        return lut
    }

    /// A cached LUT, only while the file still has the stamp it was read with.
    private func cached(_ ref: LUTRef, stamp: LUTStamp?) -> CubeLUT? {
        lock.lock(); defer { lock.unlock() }
        guard let e = cache[ref], e.stamp == stamp else { return nil }
        return e.lut
    }

    /// Drops everything (e.g. after a LUT file changed on disk).
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }
}

extension ColorPipeline {
    /// Builds the per-layer pipeline from a clip's Color effects and its media's detected properties.
    /// - Source: `clipColor.source` override, else `mediaInfo.colorSpace`, else Rec.709.
    /// - Effects in list order. Inside one effect: Basic Correction sliders -> Input LUT -> Creative (look, then
    ///   adjustments) -> Curves (RGB, then Hue Saturation) -> Wheels -> Color Range -> Vignette. Disabled or neutral sections are skipped.
    /// - The first effect's Input LUT is the conversion step and is always emitted (a disabled Basic Correction or
    ///   "none" = the built-in conversion). `.file`/`.embedded` = that LUT; `.automatic` = the media's embedded camera
    ///   LUT when `useEmbeddedLUT`, the media has one, and the effective source is S-Log3 (the Sony look LUTs expect
    ///   S-Log3 input, so they are skipped when the clip is reinterpreted). So the first effect's sliders work on the
    ///   source signal, everything after it on display-referred Rec.709.
    /// - Later effects: their Input LUT is an ordinary look at `inputLUTIntensity`.
    /// - Creative look LUT: intensity 0…100 -> 0…1.
    /// A LUT that fails to load is treated as absent.
    public static func from(clipColor c: ClipColor, mediaID: UUID, mediaInfo: MediaInfo?,
                            lutProvider: LUTProvider?) -> ColorPipeline {
        let id = c.effectiveSource(mediaSpace: mediaInfo?.colorSpace)
        let source = SourceColorSpace(id)
        // An HDR target (Rec.2020 PQ / HLG) keeps the HDR range (the output stage encodes it), as does conform off.
        let skipsToneMap = (!c.hdrConform || c.targetSpace.isHDR) && id.isHDR
        var ops: [ColorOp] = []
        if let g = c.graph {
            var lut: CubeLUT?
            if c.usesInputLUT, let ref = g.inputLUT {
                switch ref {
                case .file, .embedded: lut = lutProvider?.lut(for: ref)
                case .automatic:
                    if c.useEmbeddedLUT, mediaInfo?.embeddedLUTName != nil, id == .sLog3SGamut3Cine {
                        lut = lutProvider?.lut(for: .embedded(mediaID))
                    }
                }
            }
            ops.append(.conversion(lut))
            ops += graphOps(g, lutProvider: lutProvider)
            var p = ColorPipeline(source: source, ops: ops)
            p.skipsToneMap = skipsToneMap
            return p
        }
        for (n, e) in c.effects.enumerated() {
            let basicOn = e.isEnabled(.basicCorrection)
            if basicOn, !e.basic.isNeutral { ops.append(.basic(e.basic)) }
            if n == 0 {
                var lut: CubeLUT?
                if basicOn, c.usesInputLUT, let ref = e.inputLUT {
                    switch ref {
                    case .file, .embedded: lut = lutProvider?.lut(for: ref)
                    case .automatic:
                        if c.useEmbeddedLUT, mediaInfo?.embeddedLUTName != nil, id == .sLog3SGamut3Cine {
                            lut = lutProvider?.lut(for: .embedded(mediaID))
                        }
                    }
                }
                ops.append(.conversion(lut))
            } else if basicOn, let ref = e.inputLUT, ref != .automatic, e.inputLUTIntensity > 0,
                      let lut = lutProvider?.lut(for: ref) {
                ops.append(.look(lut, intensity: min(max(e.inputLUTIntensity, 0), 100) / 100))
            }
            if e.isEnabled(.creative) {
                // Saved grades with Shadow / Highlight tints still render exactly as before (DECISIONS 2026-10-04);
                // `hasTone` skips the pass while both tints are neutral.
                let k = e.creative
                if k.hasLook, let ref = k.look, let lut = lutProvider?.lut(for: ref) {
                    ops.append(.look(lut, intensity: min(max(k.intensity, 0), 100) / 100))
                }
                if k.hasTone { ops.append(.creative(k)) }
            }
            if e.isEnabled(.curves), !e.curves.isNeutral { ops.append(.curves(e.curves)) }
            if e.isEnabled(.curves), !e.hueCurves.isNeutral { ops.append(.hueCurves(e.hueCurves)) }
            if e.isEnabled(.wheels), !e.wheels.isNeutral { ops.append(.wheels(e.wheels)) }
            if e.isEnabled(.hslSecondary), let r = e.hslSecondary, !r.isCorrectionNeutral { ops.append(.hslSecondary(r)) }
            if e.isEnabled(.zoneBoard), let z = e.zoneBoard, !z.isNeutral { ops.append(.zoneBoard(z)) }
            if e.isEnabled(.vignette), !e.vignette.isNeutral { ops.append(.vignette(e.vignette)) }
        }
        var p = ColorPipeline(source: source, ops: ops)
        p.skipsToneMap = skipsToneMap
        return p
    }

    /// The Pro grade after its In LUT conversion (display signal): each enabled, non-neutral Step as primaries ->
    /// curves -> hue curves -> Step LUT (the LUT grades on top of the Step's balance), wrapped in a begin / end pair
    /// when a qualifier or window limits it; then the Out LUT. A LUT that fails to load is treated as absent.
    ///
    /// A column with Parallel or Layer Steps becomes one group (`ColorOp.groupBegin`): its parallel branches (the
    /// serial Step too) are averaged, the Layer Steps go over that average in order. A group lives in one GPU pass
    /// (`ColorPipelineGPU.maxGroupSections` blocks, one LUT, `maxCurves` tables): a branch that would not fit is left
    /// out. A graph with only serial Steps at Mix 100 produces the ops it always did.
    ///
    /// Key wires (`ColorGraph.keyLinks`): the key output of a donor Step (its qualifier and window, read inverted with
    /// `keyOutside`) limits the Step it feeds (one `keyTerm` before the Step's end); the keys into a mixer box combine by the
    /// stack head's `keyMix` and limit the whole stack (`keyApply`). A Layer Step composites by its `layerMix`.
    static func graphOps(_ g: ColorGraph, lutProvider: LUTProvider?) -> [ColorOp] {
        var ops: [ColorOp] = []
        func look(_ ref: LUTRef?, _ intensity: Float, into out: inout [ColorOp]) {
            guard let ref, ref != .automatic, intensity > 0, let lut = lutProvider?.lut(for: ref) else { return }
            out.append(.look(lut, intensity: min(intensity, 100) / 100))
        }
        func body(_ s: ColorStep) -> [ColorOp] {
            var out: [ColorOp] = []
            if !s.primaries.isNeutral { out.append(.primaries(s.primaries)) }
            if !s.curves.isNeutral { out.append(.curves(s.curves)) }
            if !s.hueCurves.isNeutral { out.append(.hueCurves(s.hueCurves)) }
            look(s.lut, s.lutIntensity, into: &out)
            return out
        }
        func term(_ d: ColorStep, _ mode: KeyMixMode?) -> ColorOp {
            .keyTerm(KeyTerm(qualifier: d.qualifier, window: d.window, outside: d.keyOutside, mode: mode))
        }
        /// The key wire into the key input of Step `s` (a Step's key input holds one wire).
        func stepKey(_ s: ColorStep) -> [ColorOp] {
            g.keyDonors(.step(s.id)).prefix(1).map { term($0, nil) }
        }
        func serial(_ s: ColorStep) {
            guard s.enabled, !s.isNeutral, s.mix > 0 else { return }
            let key = stepKey(s)
            let limited = s.qualifier != nil || s.window != nil || s.mix < 100 || !key.isEmpty
            if limited { ops.append(.stepBegin) }
            ops += body(s)
            ops += key
            if limited { ops.append(.stepEnd(qualifier: s.qualifier, window: s.window, mix: s.mix / 100)) }
        }
        for column in g.columns {
            let followers = column.dropFirst().filter(\.enabled)
            let parallels = ([column[0]] + followers.filter { $0.kind == .parallel }).filter(\.enabled)
            let layers = followers.filter { $0.kind == .layer && !$0.isNeutral && $0.mix > 0 }
            let mixerKeys = column.count > 1
                ? g.keyDonors(.mixer(column[0].id)).enumerated().map { term($1, $0 == 0 ? nil : column[0].keyMix) } : []
            if layers.isEmpty && parallels.count <= 1 && mixerKeys.isEmpty {
                if let only = parallels.first { serial(only) }
                continue
            }
            // The capacity of the one pass the group lives in (group begin, merge and end take three blocks).
            var sections = 3, curves = 0, luts = 0
            func plan(_ steps: [ColorStep]) -> [(ColorStep, [ColorOp])] {
                steps.compactMap { s in
                    let b = body(s) + stepKey(s)
                    var c = 0, l = 0
                    for o in b {
                        switch o { case .curves: c += 1; case .hueCurves: c += 2; case .look: l += 1; default: break }
                    }
                    guard sections + b.count + 1 <= ColorPipelineGPU.maxGroupSections,
                          curves + c <= ColorPipelineGPU.maxCurves, luts + l <= 1 else { return nil }
                    sections += b.count + 1; curves += c; luts += l
                    return (s, b)
                }
            }
            let par = plan(parallels), lay = plan(layers)
            let keys = Array(mixerKeys.prefix(max(0, ColorPipelineGPU.maxGroupSections - sections - 1)))
            ops.append(.groupBegin)
            for (s, b) in par {
                ops += b
                ops.append(.branchEnd(layer: false, qualifier: s.qualifier, window: s.window, mix: s.mix / 100))
            }
            ops.append(.groupMerge(count: par.count))
            for (s, b) in lay {
                ops += b
                if s.layerMix != .normal { ops.append(.layerMix(s.layerMix)) }
                ops.append(.branchEnd(layer: true, qualifier: s.qualifier, window: s.window, mix: s.mix / 100))
            }
            if !keys.isEmpty { ops += keys; ops.append(.keyApply) }
            ops.append(.groupEnd)
        }
        look(g.outputLUT, g.outputLUTIntensity, into: &ops)
        return ops
    }
}
