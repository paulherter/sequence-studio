import Foundation
import SSCore

extension SourceColorSpace {
    public init(_ id: ColorSpaceID) {
        switch id {
        case .rec709: self = .rec709
        case .sLog3SGamut3Cine: self = .sLog3SGamut3Cine
        case .hlgBT2020: self = .hlgBT2020
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
/// SSMedia `EmbeddedMeta.lut(inClip:)` (media ID -> file -> `EmbeddedLUT.data`).
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
    /// Builds the per-layer pipeline from a clip's colour blocks and its media's detected properties.
    /// - Source: `clipColor.source` override, else `mediaInfo.colorSpace`, else Rec.709.
    /// - Blocks in list order; disabled or neutral blocks are skipped. The Input LUT is always the conversion step
    ///   (a disabled one or "none" = the built-in automatic conversion). `.file`/`.embedded` = that LUT; `.automatic` =
    ///   the media's embedded camera LUT when `useEmbeddedLUT`, the media has one, and the effective source is S-Log3
    ///   (the Sony look LUTs expect S-Log3 input, so they are skipped when the clip is reinterpreted).
    /// - Creative look LUT: intensity 0…100 -> 0…1; look first, then the creative adjustments.
    /// A LUT that fails to load is treated as absent.
    public static func from(clipColor c: ClipColor, mediaID: UUID, mediaInfo: MediaInfo?,
                            lutProvider: LUTProvider?) -> ColorPipeline {
        let id = c.source ?? mediaInfo?.colorSpace ?? .rec709
        let source = SourceColorSpace(id)
        var ops: [ColorOp] = []
        var hasConversion = false
        for s in c.sections {
            switch s.params {
            case .inputLUT(let ref):
                guard !hasConversion else { continue }
                hasConversion = true
                var lut: CubeLUT?
                if s.enabled, let ref {
                    switch ref {
                    case .file, .embedded: lut = lutProvider?.lut(for: ref)
                    case .automatic:
                        if c.useEmbeddedLUT, mediaInfo?.embeddedLUTName != nil, id == .sLog3SGamut3Cine {
                            lut = lutProvider?.lut(for: .embedded(mediaID))
                        }
                    }
                }
                ops.append(.conversion(lut))
            case .basic(let b):
                if s.enabled, !b.isNeutral { ops.append(.basic(b)) }
            case .creative(let k):
                guard s.enabled else { continue }
                if k.hasLook, let ref = k.look, let lut = lutProvider?.lut(for: ref) {
                    ops.append(.look(lut, intensity: min(max(k.intensity, 0), 100) / 100))
                }
                if k.hasTone { ops.append(.creative(k)) }
            case .curves(let k):
                if s.enabled, !k.isNeutral { ops.append(.curves(k)) }
            case .wheels(let w):
                if s.enabled, !w.isNeutral { ops.append(.wheels(w)) }
            case .vignette(let v):
                if s.enabled, !v.isNeutral { ops.append(.vignette(v)) }
            }
        }
        if !hasConversion { ops.insert(.conversion(nil), at: 0) }
        return ColorPipeline(source: source, ops: ops)
    }
}
