import Foundation
import SQCore
import Synchronization

/// Per-frame Magic mattes by cache key and source time (seconds): what a Magic pick and its tracking make on a
/// platform without the Mac `MagicMatteStore` (Windows: EdgeTAM through ONNX Runtime). `mattes(for:)` is what the
/// compositor reads per layer, with the mask's Feather / Expansion applied.
/// With a `directory` every key lives in one `<key>.sqmatte` file, the Mac store's format (`SQMT`, version 2, 8-bit
/// frames), so a project that is reopened (or moved between the Mac and Windows with its cache) finds its mattes: the
/// project holds the picks, the files hold what tracking made (`MagicSelection.cacheKey`).
/// Frames are written raw here; the Mac store compresses them with LZFSE and reads raw frames too. A frame whose stored
/// size differs from width x height is LZFSE (`LZFSE.decode`, portable), so Mac cache files load on Windows as well.
public final class FrameMatteStore: Sendable {
    /// The app's store: `<analysis cache>/MagicMattes`.
    public static let shared = FrameMatteStore(directory: AnalysisCacheLocation.directory("MagicMattes") {
        AnalysisCacheLocation.legacyBundleDirectory("MagicMattes")
    })

    /// `directory` nil = memory only (tests).
    public init(directory: URL? = nil) {
        self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public let directory: URL?

    private struct Frame { var pts: Double; var matte: SubjectMatte }
    private struct EdgeKey: Hashable { var key: String; var pts: Double; var feather: Double; var expansion: Double; var frameWidth: Double }
    private struct State {
        var frames: [String: [Frame]] = [:]
        var edged: [(EdgeKey, SubjectMatte)] = []
        var revision = 0
        var loaded: Set<String> = []
        var unsaved: Set<String> = []
        var queued: Set<String> = []
    }
    private let state = Mutex(State())
    private let saves = DispatchQueue(label: "sq.frame-matte.save", qos: .utility)
    private let saveLock = Mutex(())
    static let fileVersion: UInt32 = 2
    private static let edgedLimit = 24

    /// Bumps whenever a matte is stored or removed (callers that cache a drawing by it).
    public var revision: Int { state.withLock { $0.revision } }

    public func put(key: String, pts: Double, matte: SubjectMatte) {
        load(key)
        state.withLock { s in
            s.unsaved.insert(key)
            var list = s.frames[key] ?? []
            list.removeAll { abs($0.pts - pts) < 1e-6 }
            list.append(Frame(pts: pts, matte: matte))
            list.sort { $0.pts < $1.pts }
            s.frames[key] = list
            s.edged.removeAll { $0.0.key == key }
            s.revision += 1
        }
    }

    public func times(key: String) -> [Double] { load(key); return state.withLock { $0.frames[key]?.map(\.pts) ?? [] } }

    /// Matte coverage (0...1) of every stored frame of `key`, in time order: the input of the confidence strip
    /// (`MagicTrackHealth.weakSpans`), like `MagicMatteStore.healthSamples` on the Mac. Frames at or under half an 8-bit step
    /// count as empty, as the Mac store's 8-bit data does.
    public func healthSamples(key: String) -> [MagicTrackHealth.Sample] {
        load(key)
        let list = state.withLock { $0.frames[key] ?? [] }
        return list.map { f in
            let n = f.matte.width * f.matte.height
            let sum = f.matte.values.reduce(0.0) { $0 + Double((min(max($1, 0), 1) * 255).rounded()) }
            return MagicTrackHealth.Sample(pts: f.pts, area: sum / (255 * Double(n)))
        }
    }

    public func has(key: String) -> Bool { load(key); return state.withLock { !($0.frames[key]?.isEmpty ?? true) } }

    public func remove(key: String) {
        load(key)
        state.withLock { s in
            s.unsaved.remove(key)
            if let url = file(key) { try? FileManager.default.removeItem(at: url) }
            s.frames[key] = nil
            s.edged.removeAll { $0.0.key == key }
            s.revision += 1
        }
    }

    /// The stored matte of the frame at `pts` (the last one at or before it, no further than the frame spacing away).
    public func matte(key: String, pts: Double) -> SubjectMatte? {
        load(key)
        return state.withLock { s in s.frames[key].flatMap { Self.nearest($0, pts) }?.matte }
    }

    /// The matte at `pts` with the mask's edge (Feather / Expansion in px of a frame `frameWidth` px wide).
    public func matte(key: String, pts: Double, feather: Double, expansion: Double, frameWidth: Double) -> SubjectMatte? {
        load(key)
        let hit: (Frame, EdgeKey)? = state.withLock { s in
            guard let f = s.frames[key].flatMap({ Self.nearest($0, pts) }) else { return nil }
            return (f, EdgeKey(key: key, pts: f.pts, feather: feather, expansion: expansion, frameWidth: frameWidth))
        }
        guard let (frame, ek) = hit else { return nil }
        if let cached = state.withLock({ s in s.edged.first { $0.0 == ek }?.1 }) { return cached }
        let out = Self.edge(frame.matte, feather: feather, expansion: expansion, frameWidth: frameWidth)
        state.withLock { s in
            // Stored again meanwhile: the new frame is edged when it is asked for.
            guard s.frames[key]?.contains(where: { abs($0.pts - frame.pts) < 1e-6 && $0.matte == frame.matte }) ?? false else { return }
            s.edged.append((ek, out))
            if s.edged.count > Self.edgedLimit { s.edged.removeFirst(s.edged.count - Self.edgedLimit) }
        }
        return out
    }

    /// The mattes a layer's masks read (`RenderLayer.mattes`); a mask without a matte at `pts` is left out ("not tracked
    /// here": nothing picked).
    public func mattes(for fx: ClipEffects, pts: Double, frameWidth: Double) -> [UUID: SubjectMatte] {
        var out: [UUID: SubjectMatte] = [:]
        for m in fx.magicMattes where !m.cacheKey.isEmpty {
            if let x = matte(key: m.cacheKey, pts: pts, feather: m.feather, expansion: m.expansion, frameWidth: frameWidth) {
                out[m.mask] = x
            }
        }
        return out
    }

    /// Copies the frames of `from` whose time passes `keep` to `to` (frames there at the same times are replaced): a
    /// corrected pick keeps the tracked frames the correction does not change. Returns how many moved.
    @discardableResult
    public func copyFrames(from: String, to: String, where keep: (Double) -> Bool) -> Int {
        load(from); load(to)
        return state.withLock { s in
            let moved = (s.frames[from] ?? []).filter { keep($0.pts) }
            guard !moved.isEmpty else { return 0 }
            var list = (s.frames[to] ?? []).filter { f in !moved.contains { abs($0.pts - f.pts) < 1e-6 } }
            list.append(contentsOf: moved)
            list.sort { $0.pts < $1.pts }
            s.frames[to] = list
            s.edged.removeAll { $0.0.key == to }
            s.unsaved.insert(to)
            s.revision += 1
            return moved.count
        }
    }

    // MARK: Files

    private func file(_ key: String) -> URL? { directory?.appendingPathComponent("\(key).sqmatte") }

    /// Reads a key's file once (frames put meanwhile win over the file's at the same time).
    public func load(_ key: String) {
        guard state.withLock({ !$0.loaded.contains(key) }) else { return }
        var read: [Frame] = []
        if let url = file(key), let data = try? Data(contentsOf: url) { read = Self.parse(data) }
        state.withLock { s in
            guard !s.loaded.contains(key) else { return }
            s.loaded.insert(key)
            let mem = s.frames[key] ?? []
            guard !read.isEmpty else { return }
            var all = read.filter { f in !mem.contains { abs($0.pts - f.pts) < 1e-6 } } + mem
            all.sort { $0.pts < $1.pts }
            s.frames[key] = all
            s.revision += 1
        }
    }

    /// Keys whose frames in memory are not in their file.
    public var unsavedKeys: Set<String> { state.withLock { $0.unsaved } }

    /// Writes a key's frames to its file (one writer at a time; each reads the frames when it runs).
    public func save(key: String) {
        guard let url = file(key) else { return }
        saveLock.withLock { _ in
            let list: [Frame] = state.withLock { s in s.unsaved.remove(key); return s.frames[key] ?? [] }
            if list.isEmpty { try? FileManager.default.removeItem(at: url); return }
            try? Self.encode(list).write(to: url, options: .atomic)
        }
    }

    /// `save` off the calling thread, after the saves queued before it.
    public func saveLater(key: String) {
        guard directory != nil, state.withLock({ $0.queued.insert(key).inserted }) else { return }
        saves.async { [self] in
            state.withLock { _ = $0.queued.remove(key) }
            save(key: key)
        }
    }

    /// Returns when every save queued so far is in its file (quit; tests).
    public func waitForSaves() { saves.sync {} }

    private static func encode(_ list: [Frame]) -> Data {
        var out = Data("SQMT".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }
        put(fileVersion); put(UInt32(list.count))
        for f in list {
            let n = f.matte.values.count
            var bytes = [UInt8](repeating: 0, count: n)
            for i in 0..<n { bytes[i] = UInt8((min(max(f.matte.values[i], 0), 1) * 255).rounded()) }
            put(f.pts); put(UInt32(f.matte.width)); put(UInt32(f.matte.height)); put(UInt32(n))
            out.append(contentsOf: bytes)
        }
        return out
    }

    /// The raw frames of a file; frames the Mac store compressed (size differs from width x height) are decoded with LZFSE.
    private static func parse(_ d: Data) -> [Frame] {
        var i = 0
        func take<T>(_: T.Type) -> T? {
            let n = MemoryLayout<T>.size
            guard i + n <= d.count else { return nil }
            defer { i += n }
            return d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + n)).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
        guard d.count >= 12, String(data: d.prefix(4), encoding: .utf8) == "SQMT" else { return [] }
        i = 4
        guard take(UInt32.self) == fileVersion, let count = take(UInt32.self) else { return [] }
        var out: [Frame] = []
        for _ in 0..<count {
            guard let pts = take(Double.self), let w = take(UInt32.self), let h = take(UInt32.self), let n = take(UInt32.self),
                  i + Int(n) <= d.count else { break }
            defer { i += Int(n) }
            guard w > 0, h > 0 else { continue }
            let size = Int(w) * Int(h)
            let stored = d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + Int(n)))
            guard let raw = Int(n) == size ? stored : LZFSE.decode(stored, size: size) else { continue }
            let bytes = [UInt8](raw)
            out.append(Frame(pts: pts, matte: SubjectMatte(width: Int(w), height: Int(h), values: bytes.map { Float($0) / 255 })))
        }
        return out
    }

    private static func nearest(_ list: [Frame], _ pts: Double) -> Frame? {
        let t = pts + 1e-6
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].pts > t { hi = mid } else { lo = mid + 1 }
        }
        guard lo > 0 else { return nil }
        let best = list[lo - 1]
        var spacing = 0.05
        if list.count > 1 {
            spacing = .infinity
            if lo - 1 > 0 { spacing = min(spacing, best.pts - list[lo - 2].pts) }
            if lo < list.count { spacing = min(spacing, list[lo].pts - best.pts) }
        }
        return t - best.pts < spacing + 1e-6 ? best : nil
    }

    /// The Mac store's edge: positive `expansion` grows the subject, `feather` is the soft edge width (box radius
    /// feather / 2); both in px of a `frameWidth` px wide frame, scaled to the matte.
    static func edge(_ m: SubjectMatte, feather: Double, expansion: Double, frameWidth: Double) -> SubjectMatte {
        let scale = Double(m.width) / max(frameWidth, 1)
        let refine = MatteRefine(feather: feather * scale / 2, shrinkPx: -expansion * scale)
        guard !refine.isSpatialIdentity else { return m }
        return SubjectMatte(width: m.width, height: m.height, values: refine.refine(m.values, width: m.width, height: m.height))
    }
}
