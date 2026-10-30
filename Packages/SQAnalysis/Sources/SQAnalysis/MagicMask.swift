import Accelerate
import CoreML
import CoreVideo
import Foundation
import SQCore
import Synchronization
import Vision

// Magic masks: hover/click picking and Track (forward / backward) on Vision's foreground instance masks, all local.
// Picking runs on the frame shown in the Program monitor; Track reads the source file shrunk (`FrameReader`, the same
// reader mask tracking uses) and stores one matte per frame in `MagicMatteStore`. Playback and export only read the
// store, never run Vision for a Magic mask.

/// A subject frame request that got no picture to work on.
public enum SubjectFrameError: Error, LocalizedError, Equatable {
    /// The file handed out no frame at this source time (seconds).
    case noFrame(Double)

    public var errorDescription: String? {
        switch self {
        case .noFrame(let s): String(format: "the file gave no frame at %.3f s", s)
        }
    }
}

/// Segments one upright frame into objects (Vision in the app, a fake in tests).
public protocol InstanceSegmenting: Sendable {
    func segment(_ frame: CVPixelBuffer) throws -> InstanceFrame?
}

/// The leg's segmenter with its calls counted (`SubjectMaskTiming`, stage `vision`).
struct TimedSegmenter: InstanceSegmenting {
    let base: any InstanceSegmenting
    init(_ base: any InstanceSegmenting) { self.base = base }
    func segment(_ frame: CVPixelBuffer) throws -> InstanceFrame? { try SubjectMaskTiming.measure("vision") { try base.segment(frame) } }
}

/// Vision's foreground instance segmentation (people, animals, objects). Labels come at Vision's mask size (512 x 512);
/// soft mattes from `generateScaledMaskForImage(forInstances:from:)` at the analyzed frame's size.
public struct VisionInstanceSegmenter: InstanceSegmenting {
    public init() {}

    public func segment(_ frame: CVPixelBuffer) throws -> InstanceFrame? {
        // The Neural Engine plan can fail to load (sandboxed or busy ANE). Each request falls back by itself: the default
        // devices first, the CPU when that throws (`ComputeFallback`).
        let (request, handler) = try Self.compute.run { cpu in
            let request = VNGenerateForegroundInstanceMaskRequest()
            if cpu { Self.useCPU(request) }
            let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:])
            try handler.perform([request])
            return (request, handler)
        }
        guard let obs = request.results?.first else { return nil }
        guard let labels = Self.labels(obs.instanceMask) else { return nil }
        // The observation and handler are kept for later soft mattes of any label set; Vision is not thread-safe per
        // handler, so one soft matte is made at a time. Nobody ever waits for another one's Vision call: a second
        // caller at the same moment gets the hard labels (it does not happen in the app: a frame's soft mattes are made
        // on one thread or one serial queue).
        let box = SoftBox(obs: obs, handler: handler)
        let w = labels.width, h = labels.height
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame)
        return InstanceFrame(labels: labels, guide: Self.guide(frame)) { set in
            let ids = IndexSet(set.filter { $0 != 0 }.map(Int.init))
            guard !ids.isEmpty else { return SubjectMatte(width: w, height: h, values: [Float](repeating: 0, count: w * h)) }
            guard box.lock.try() else { return MagicPick.usableSoft(nil, labels: labels, selected: set) }
            // The mask scaled to the analyzed frame: Vision's own mask is 512 x 512 whatever the frame's shape, so a
            // 16:9 frame had 512 columns for its width; the scaled mask has the frame's pixels and follows its edges.
            let soft = (try? box.obs.generateScaledMaskForImage(forInstances: ids, from: box.handler))
                ?? (try? box.obs.generateMask(forInstances: ids))
            box.lock.unlock()
            // Wrong size or blank (seen as an all-black picture): the hard labels instead.
            return MagicPick.usableSoft(soft.flatMap(PersonSegmenter.matte(from:)), labels: labels, selected: set,
                                        frameWidth: fw, frameHeight: fh)
        }
    }

    /// Shared by the Vision requests of Magic and Anonymize (same Neural Engine, same failure).
    static let compute = ComputeFallback(name: "Magic")

    /// Pins `r` to the CPU; false when Vision offers no CPU device for it (the request then runs as it is).
    @discardableResult
    static func useCPU(_ r: VNRequest) -> Bool {
        guard let stages = try? r.supportedComputeStageDevices, let devices = stages[.main] else { return false }
        for d in devices {
            if case .cpu = d { r.setComputeDevice(d, for: .main); return true }
        }
        return false
    }

    private final class SoftBox: @unchecked Sendable {
        let obs: VNInstanceMaskObservation
        let handler: VNImageRequestHandler
        let lock = NSLock()
        init(obs: VNInstanceMaskObservation, handler: VNImageRequestHandler) { self.obs = obs; self.handler = handler }
    }

    /// The frame's picture shrunk to the corrections' grid (`MagicCorrection.gridMax`), RGB 0...1. nil for a frame that is
    /// not BGRA (corrections then work per object only).
    static func guide(_ pb: CVPixelBuffer) -> MagicGuide? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0, CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        let s = min(1, Double(MagicCorrection.gridMax) / Double(max(w, h)))
        let gw = max(1, Int((Double(w) * s).rounded())), gh = max(1, Int((Double(h) * s).rounded()))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        var small = [UInt8](repeating: 0, count: gw * gh * 4)
        let ok = small.withUnsafeMutableBytes { d -> Bool in
            var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRow(pb))
            var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(gh), width: vImagePixelCount(gw), rowBytes: gw * 4)
            return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok else { return nil }
        var rgb = [Float](repeating: 0, count: gw * gh * 3)
        for i in 0..<(gw * gh) {
            rgb[i * 3] = Float(small[i * 4 + 2]) / 255
            rgb[i * 3 + 1] = Float(small[i * 4 + 1]) / 255
            rgb[i * 3 + 2] = Float(small[i * 4]) / 255
        }
        return MagicGuide(width: gw, height: gh, rgb: rgb)
    }

    /// The instance label buffer (one byte per pixel) as `InstanceLabels`.
    static func labels(_ pb: CVPixelBuffer) -> InstanceLabels? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0, CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { out[y * w + x] = row[x] }
        }
        return InstanceLabels(width: w, height: h, labels: out)
    }
}

/// Some stored frames of one key, as kept (compressed): the undo state of deleting tracked frames.
public struct MagicFrameSnapshot: Sendable {
    let key: String
    let frames: [MagicMatteStore.Frame]
    public var isEmpty: Bool { frames.isEmpty }
    public var count: Int { frames.count }
    public var times: [Double] { frames.map { $0.pts } }
    public var storeKey: String { key }
}

/// Per-frame Magic mattes, by cache key (`MagicSelection.cacheKey`) and source time. Kept compressed in memory (8-bit,
/// LZFSE) and in one file per key under `directory`; decoded mattes (with their edge) sit in a small LRU so playback
/// pays the decode once per frame. Thread-safe.
public final class MagicMatteStore: Sendable {
    struct Frame: Sendable { var pts: Double; var width: Int; var height: Int; var data: Data }
    struct EdgedKey: Hashable {
        var key: String; var pts: Double; var feather: Double; var expansion: Double; var frameWidth: Double
        /// A matte drawn in a hole of the tracking (`filledFrame`): the stored frame at `pts` moved toward the one at
        /// `toward` as far as the hole frame at `gap` lies between them. nil = the stored frame as it is.
        var toward: Double? = nil
        var gap: Double? = nil
    }

    private struct State {
        var frames: [String: [Frame]] = [:]          // sorted by pts
        var loaded: Set<String> = []
        var lru: [(EdgedKey, SubjectMatte)] = []
        var decodes = 0
        /// Decodes made by a playback read itself (`playing`), not by the look-ahead: what the render thread paid.
        var inlineDecodes = 0
        /// Mattes the look-ahead is making on `work` (`prepare`).
        var preparing: Set<EdgedKey> = []
        /// What the look-ahead asked for lately, per mask edge (an `EdgedKey` with pts 0): how many decoded mattes its
        /// playback keeps live (the shown one, the ones ahead, a margin) and when it asked last.
        var need: [EdgedKey: (count: Int, at: ContinuousClock.Instant)] = [:]

        /// Decoded mattes the LRU holds now: the fixed size, or what the masks playing within the last second need
        /// together (seven masks ahead of each other must not push the next frame's matte out before it is shown).
        mutating func capacity(now: ContinuousClock.Instant) -> Int {
            if !need.isEmpty { need = need.filter { now - $0.value.at < wantedWindow } }
            return max(MagicMatteStore.lruCapacity, need.values.reduce(0) { $0 + $1.count })
        }

        /// Drops the mattes used longest ago beyond the capacity and beyond `lruByteLimit` (never the newest one).
        mutating func trim(now: ContinuousClock.Instant) {
            let cap = capacity(now: now)
            if lru.count > cap { lru.removeFirst(lru.count - cap) }
            var bytes = lru.reduce(0) { $0 + $1.1.values.count * MemoryLayout<Float>.size }
            while bytes > MagicMatteStore.lruByteLimit, lru.count > 1 {
                bytes -= lru.removeFirst().1.values.count * MemoryLayout<Float>.size
            }
        }
        /// Keys written since the last sweep (a pick that changed leaves its old key behind).
        var written: Set<String> = []
        /// Keys whose frames in memory differ from their file (put, restored, copied or deleted since the last write).
        var unsaved: Set<String> = []
        /// Keys with a save waiting on `saves`.
        var queued: Set<String> = []
        /// Keys removed and not used since: a save that arrives late (a stopped run's, behind the sweep at project
        /// close) writes nothing for them.
        var removed: Set<String> = []
        /// The last keys written, oldest first (tests).
        var saveLog: [String] = []

        /// The frames of `key` changed in memory.
        mutating func touch(_ key: String) {
            unsaved.insert(key)
            removed.remove(key)
        }
        /// Grown mattes of masks that must cover (`grown`), kept apart from the LRU: playing through tracked frames must
        /// not push them out before the gap they are for arrives.
        var grown: [EdgedKey: SubjectMatte] = [:]
        var grownOrder: [EdgedKey] = []
        /// Grown mattes being made on `work`.
        var pending: Set<EdgedKey> = []
        /// Grown mattes whose stored frame would not decode: not asked again until the store changes (stays whole frame).
        var failed: Set<EdgedKey> = []
        /// Grown mattes the shown frame asks for (all covers of it): never evicted while it stays on screen.
        /// Asked within `wantedWindow` (a frame request spans milliseconds, and several clips or monitors ask for
        /// different source times): keyed by request time, not by source time, so covers of one frame never evict each other.
        var wanted: [EdgedKey: ContinuousClock.Instant] = [:]
        var wantedWindow = MagicMatteStore.wantedWindow
        func isWanted(_ k: EdgedKey, now: ContinuousClock.Instant) -> Bool {
            wanted[k].map { now - $0 < wantedWindow } ?? false
        }
        var observers: [UUID: @Sendable () -> Void] = [:]

        /// Drops every decoded matte of `key` (only those at times passing `hit` when given).
        mutating func forget(_ key: String, where hit: ((Double) -> Bool)? = nil) {
            lru.removeAll { $0.0.key == key && (hit?($0.0.pts) ?? true) }
            if !failed.isEmpty { failed = failed.filter { !($0.key == key && (hit?($0.pts) ?? true)) } }
            guard !grown.isEmpty else { return }
            grownOrder.removeAll { $0.key == key && (hit?($0.pts) ?? true) }
            grown = grown.filter { !($0.key.key == key && (hit?($0.key.pts) ?? true)) }
        }
    }

    /// Most other frames mixed into one (frame blending, temporal filters) a cover follows one by one; past that the
    /// caller asks for the whole frame (`warped`).
    public static let maxNeighbors = 8
    /// Matte file format. 2 (2026-10-19): files tracked before FrameReader mapped compressed media pts through the edit
    /// list hold pts one frame early on B-frame camera files (the mask ran ahead), so version 1 files are dropped and
    /// tracked again.
    static let fileVersion: UInt32 = 2
    /// Grown mattes kept (a gap needs three per side).
    static let grownCapacity = 36
    static let wantedWindow: Duration = .seconds(1)
    /// How far around the shown frame a gap in the tracking is looked for, in seconds: its grown mattes are made ahead.
    static let warmReach = 0.5
    /// File reads and grown mattes for playback, off the render thread.
    private let work = DispatchQueue(label: "sq.magic-matte.cover", qos: .userInitiated)
    /// The playback look-ahead's own lane (`prepare`): the frames the next ticks show never wait behind a file read
    /// or a grown matte on `work`, or the render thread decodes them itself.
    private let ahead = DispatchQueue(label: "sq.magic-matte.ahead", qos: .userInteractive)

    public let directory: URL?
    private let state = Mutex(State())
    /// Decoded mattes kept for redraws; more while several masks play (`State.capacity`).
    public static let lruCapacity = 24
    /// Decoded mattes a playing mask keeps beside the shown one and the ones prepared ahead.
    static let lookAheadMargin = 2
    /// Most memory the decoded mattes take, whatever the masks ask for (a 540 x 960 matte: 2 MB, a Quality matte of
    /// 1920 x 1080: 8.3 MB, so the 24 kept for redraws are 199 MB).
    static let lruByteLimit = 384 << 20
    /// Decoded mattes held now (tests).
    var lruCount: Int { state.withLock { $0.lru.count } }

    /// The app's store: `~/Library/Caches/<bundle>/MagicMattes`.
    public static let shared: MagicMatteStore = {
        let dir = AnalysisCacheLocation.directory("MagicMattes") { AnalysisCacheLocation.legacyBundleDirectory("MagicMattes") }
        return MagicMatteStore(directory: dir)
    }()

    /// `directory` nil = memory only (tests).
    public init(directory: URL?) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Staged mattes of a run that never ended (the app quit meanwhile).
            for f in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where f.lastPathComponent.hasPrefix(Self.stagedPrefix) { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Keys a run writes to before its result is taken over (`adopt`): never a mask's own key, so a canceled or failed
    /// run cannot touch mattes a mask draws.
    public static let stagedPrefix = "tmp-"

    /// Takes the frames of the staged key `temp` over into `key` (frames there at the same times are replaced, all others
    /// stay), writes the file and forgets `temp`.
    public func adopt(from temp: String, into key: String) {
        copyFrames(from: temp, to: key) { _ in true }
        save(key: key)
        remove(key: temp)
    }

    /// Stores the matte of one frame (replaces a frame at the same time).
    public func put(_ m: SubjectMatte, key: String, pts: Double) {
        let n = m.values.count
        var bytes = [UInt8](repeating: 0, count: n)
        var vals = m.values
        vals.withUnsafeMutableBytes { s in
            bytes.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                var dst = vImage_Buffer(data: d.baseAddress, height: 1, width: vImagePixelCount(n), rowBytes: n)
                _ = vImageConvert_PlanarFtoPlanar8(&src, &dst, 1, 0, vImage_Flags(kvImageNoFlags))
            }
        }
        let data = (try? (Data(bytes) as NSData).compressed(using: .lzfse) as Data) ?? Data(bytes)
        let f = Frame(pts: pts, width: m.width, height: m.height, data: data)
        load(key)
        state.withLock { s in
            var list = s.frames[key] ?? []
            if let i = list.firstIndex(where: { abs($0.pts - pts) < 1e-6 }) { list[i] = f }
            else {
                let at = list.firstIndex { $0.pts > pts } ?? list.count
                list.insert(f, at: at)
            }
            s.frames[key] = list
            s.forget(key) { abs($0 - pts) < 1e-6 }
            s.written.insert(key)
            s.touch(key)
        }
    }

    /// Marks the frame at `pts` as tracked without the subject (`MagicMaskTracker.lostMatte`). A matte with something
    /// in it that is already stored there stays: one frame the segmenter misses while a part is tracked again (or the
    /// backward leg reads the pick's frame again) must not blank a good matte. False when the stored matte stayed.
    @discardableResult
    public func putLost(key: String, pts: Double) -> Bool {
        load(key)
        let held = state.withLock { s in s.frames[key]?.first { abs($0.pts - pts) < 1e-6 } }
        if let held, !Self.isBlank(held) { return false }
        put(MagicMaskTracker.lostMatte, key: key, pts: pts)
        return true
    }

    /// Nothing of the picture is in the stored matte (also when it cannot be read).
    static func isBlank(_ f: Frame) -> Bool {
        let n = f.width * f.height
        if f.data.count == n { return !f.data.contains { $0 != 0 } }
        guard let d = try? (f.data as NSData).decompressed(using: .lzfse) as Data, d.count == n else { return true }
        return !d.contains { $0 != 0 }
    }

    /// The key's file was read (or the key is memory only): lookups no longer touch the disk.
    public func isLoaded(_ key: String) -> Bool { state.withLock { $0.loaded.contains(key) } }

    /// Reads the key's file now (off the render thread), so later lookups never wait on the disk.
    public func preload(_ key: String) { load(key) }

    /// Reads the files of `keys` in the background (playback: when a timeline is set and whenever a cover finds its key
    /// not read yet). Observers hear when they are in.
    public func preloadSoon(_ keys: some Sequence<String>) {
        let todo = state.withLock { s in keys.filter { !$0.isEmpty && !s.loaded.contains($0) } }
        guard !todo.isEmpty else { return }
        work.async { [self] in
            todo.forEach(load)
            notifyReady()
        }
    }

    /// `f` runs (on a background queue) whenever something a frame was waiting for is there: a key's file was read, a
    /// grown matte was made. Playback redraws.
    @discardableResult
    public func observeReady(_ f: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        state.withLock { $0.observers[id] = f }
        return id
    }

    public func removeObserver(_ id: UUID) { state.withLock { $0.observers[id] = nil } }

    private func notifyReady() {
        let all = state.withLock { Array($0.observers.values) }
        for f in all { f() }
    }

    /// Returns when the background work asked for so far is done (tests).
    public func waitForCovers() { waitForLookAhead(); work.sync {} }
    /// Returns when the look-ahead asked for so far is done (twice: a `prepare` that had to read a file asks again).
    func waitForLookAhead() { ahead.sync {}; ahead.sync {} }
    /// Keeps file reads and grown mattes waiting until `gate` is signaled (tests).
    func holdWork(until gate: DispatchSemaphore) { work.async { gate.wait() } }

    /// Keys written since the last sweep.
    public var writtenKeys: Set<String> { state.withLock { $0.written } }

    /// Removes the keys written since the last sweep that `keeping` does not list (memory and file): a changed pick or a
    /// deleted mask left them behind. Run when the project's saved state is what is open (close, open another), so undo
    /// within the session never finds its mattes gone. Returns the removed keys.
    @discardableResult
    public func sweep(keeping: Set<String>) -> [String] {
        let gone = state.withLock { s -> [String] in
            let g = s.written.subtracting(keeping)
            s.written = []
            return Array(g)
        }
        for k in gone { remove(key: k) }
        return gone.sorted()
    }

    /// Forgets which keys were written without removing anything (the open project is not saved: its file may still
    /// refer to them).
    public func forgetWritten() { state.withLock { $0.written = [] } }

    /// Source times stored for `key` (sorted).
    public func times(key: String) -> [Double] {
        load(key)
        return state.withLock { $0.frames[key]?.map(\.pts) ?? [] }
    }

    /// Drops the frames of `key` stored at `times` (source seconds, within 1e-6), in memory; `save(key:)` writes the file.
    /// Deleting tracked frames from the keyframe lanes. Returns how many frames went.
    @discardableResult
    public func removeFrames(key: String, times: [Double]) -> Int {
        guard !times.isEmpty else { return 0 }
        load(key)
        func hit(_ pts: Double) -> Bool { times.contains { abs($0 - pts) < 1e-6 } }
        return state.withLock { s in
            let before = s.frames[key]?.count ?? 0
            s.frames[key]?.removeAll { hit($0.pts) }
            s.forget(key, where: hit)
            let gone = before - (s.frames[key]?.count ?? 0)
            if gone > 0 { s.unsaved.insert(key) }
            return gone
        }
    }

    /// Redo of a delete: removes exactly the frames of `snapshot`, i.e. a stored frame goes only when its time AND its
    /// matte equal the snapshot's. A frame tracked again at the same time since the undo is a different frame and stays.
    /// Returns the times that went.
    @discardableResult
    public func removeFrames(matching snapshot: MagicFrameSnapshot) -> [Double] {
        guard !snapshot.frames.isEmpty else { return [] }
        load(snapshot.key)
        return state.withLock { s in
            var gone: [Double] = []
            for f in snapshot.frames {
                guard let i = s.frames[snapshot.key]?.firstIndex(where: {
                    abs($0.pts - f.pts) < 1e-6 && $0.width == f.width && $0.height == f.height && $0.data == f.data
                }) else { continue }
                let pts = s.frames[snapshot.key]![i].pts
                s.frames[snapshot.key]?.remove(at: i)
                s.forget(snapshot.key) { abs($0 - pts) < 1e-6 }
                gone.append(pts)
            }
            if !gone.isEmpty { s.unsaved.insert(snapshot.key) }
            return gone
        }
    }

    /// The frames of `key` stored at `times` (within 1e-6), compressed as kept: only those, so an undo snapshot of a
    /// delete costs what was deleted.
    public func snapshotFrames(key: String, times: [Double]) -> MagicFrameSnapshot {
        guard !times.isEmpty else { return MagicFrameSnapshot(key: key, frames: []) }
        load(key)
        let kept = state.withLock { s in (s.frames[key] ?? []).filter { f in times.contains { abs($0 - f.pts) < 1e-6 } } }
        return MagicFrameSnapshot(key: key, frames: kept)
    }

    /// Puts a snapshot's frames back (replacing frames at the same times); `save(key:)` writes the file.
    public func restore(_ snapshot: MagicFrameSnapshot) {
        guard !snapshot.frames.isEmpty else { return }
        load(snapshot.key)
        state.withLock { s in
            var list = s.frames[snapshot.key] ?? []
            for f in snapshot.frames {
                if let i = list.firstIndex(where: { abs($0.pts - f.pts) < 1e-6 }) { list[i] = f }
                else { list.insert(f, at: list.firstIndex { $0.pts > f.pts } ?? list.count) }
                s.forget(snapshot.key) { abs($0 - f.pts) < 1e-6 }
            }
            s.frames[snapshot.key] = list
            s.written.insert(snapshot.key)
            s.touch(snapshot.key)
        }
    }

    /// Matte coverage (0...1) of every stored frame of `key`, in time order: the input of the confidence strip
    /// (`MagicTrackHealth.weakSpans`). Reads the 8-bit data only, no float decode. Not for the render thread.
    public func healthSamples(key: String) -> [MagicTrackHealth.Sample] {
        load(key)
        let list = state.withLock { $0.frames[key] ?? [] }
        return list.compactMap { f in
            let n = f.width * f.height
            guard n > 0 else { return nil }
            let raw: Data
            if f.data.count == n { raw = f.data }
            else if let d = try? (f.data as NSData).decompressed(using: .lzfse) as Data, d.count == n { raw = d }
            else { return nil }
            var sum = 0
            for b in raw { sum += Int(b) }
            return MagicTrackHealth.Sample(pts: f.pts, area: Double(sum) / (255 * Double(n)))
        }
    }

    /// Decodes done so far (tests: the LRU spares redraws).
    public var decodes: Int { state.withLock { $0.decodes } }
    /// Decodes a playback read (`playing`) made itself because the look-ahead had nothing near (tests, measurements).
    public var inlineDecodes: Int { state.withLock { $0.inlineDecodes } }

    /// The stored frame shown at source time `pts`: the last one with pts <= t (like `SampleIndex.frame(at:)`, the
    /// monitor's rule), valid for one frame spacing after it (spacing: the smaller distance to its two neighbors;
    /// 0.05 s for a lone frame). nil = not tracked there. A time in the later half of a frame gave the next frame's
    /// matte with a nearest rule: the overlays, which ask with the playhead's source time, led the picture by a frame.
    func nearest(_ list: [Frame], _ pts: Double) -> Frame? {
        guard !list.isEmpty else { return nil }
        let t = pts + 1e-6                  // exact frame pts (Double from a rational time) stay on their frame
        var lo = 0, hi = list.count         // first frame with pts > t
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].pts > t { hi = mid } else { lo = mid + 1 }
        }
        guard lo > 0 else { return nil }
        let best = lo - 1
        // The smaller spacing of the two sides: next to a hole in the tracked frames the hole is not the frame spacing
        // (it made the frames of a hole count as tracked); `filling` answers inside a short hole.
        var spacing = 0.05
        if list.count > 1 {
            spacing = .infinity
            if best + 1 < list.count { spacing = min(spacing, list[best + 1].pts - list[best].pts) }
            if best > 0 { spacing = min(spacing, list[best].pts - list[best - 1].pts) }
        }
        // Up to (not including) the next frame's time: a hole's first missing frame is not the frame before it.
        return pts - list[best].pts < spacing - 1e-6 ? list[best] : nil
    }

    /// A hole of at most this many frames between two tracked frames is drawn with the nearer one (`filling`).
    static let fillFrames = 2

    /// The stored frame drawn for a source time that has none: the nearer of the two tracked frames around it when at
    /// most `fillFrames` frames are missing between them (a frame the track skipped: one the decoder dropped, a read
    /// that stalled). nil for a longer hole and outside the tracked span: not tracked there. The frame spacing is the
    /// smaller one of the tracked frames next to the hole; without such a pair there is nothing to judge by.
    func filling(_ list: [Frame], _ pts: Double) -> Frame? {
        guard list.count >= 3 else { return nil }
        var lo = 0, hi = list.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].pts < pts { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, list[lo].pts >= pts else { return nil }
        let a = list[lo - 1], b = list[lo]
        var spacing = Double.infinity
        if lo >= 2 { spacing = min(spacing, a.pts - list[lo - 2].pts) }
        if lo + 1 < list.count { spacing = min(spacing, list[lo + 1].pts - b.pts) }
        guard spacing.isFinite, spacing > 0, b.pts - a.pts <= (Double(Self.fillFrames) + 1.5) * spacing else { return nil }
        return pts - a.pts <= b.pts - pts + 1e-9 ? a : b
    }

    /// What a frame in a short hole is drawn from: the nearer tracked neighbor, moved by the way the matte center travels
    /// between the two tracked frames (`toward`: the other one, `gap`: the hole frame). Without a hole `toward`/`gap` are nil.
    func filledFrame(_ list: [Frame], _ pts: Double) -> (frame: Frame, toward: Double?, gap: Double?)? {
        if let f = nearest(list, pts) { return (f, nil, nil) }
        guard let a = filling(list, pts) else { return nil }
        // `filling` answers with one of the two frames around `pts`: the other one is the neighbor on the far side.
        guard let i = list.firstIndex(where: { $0.pts == a.pts }) else { return (a, nil, nil) }
        let j = a.pts <= pts ? i + 1 : i - 1
        guard list.indices.contains(j) else { return (a, nil, nil) }
        return (a, list[j].pts, pts)
    }

    /// The key of the edged matte a frame in `list` draws at `pts` (a hole's frame carries its shift).
    private func edgedKey(_ key: String, _ list: [Frame], _ pts: Double, feather: Double, expansion: Double,
                          frameWidth: Double) -> (EdgedKey, Frame)? {
        guard let d = filledFrame(list, pts) else { return nil }
        return (EdgedKey(key: key, pts: d.frame.pts, feather: feather, expansion: expansion, frameWidth: frameWidth,
                         toward: d.toward, gap: d.gap), d.frame)
    }

    /// The stored frame an ordinary mask draws at `pts`: its own, or the nearest one across a short hole. The export
    /// warning counts by the same rule, so it agrees with the picture.
    func drawn(_ list: [Frame], _ pts: Double) -> Frame? { nearest(list, pts) ?? filling(list, pts) }

    /// The raw matte at `pts`, nil when that frame is not tracked.
    public func matte(key: String, pts: Double) -> SubjectMatte? {
        load(key)
        guard let f = state.withLock({ s in s.frames[key].flatMap { nearest($0, pts) } }) else { return nil }
        return Self.decode(f)
    }

    /// The matte at `pts` with the mask's edge applied (Feather / Expansion in px of a frame `frameWidth` px wide),
    /// from the LRU when it was made before. `fills` (drawing an ordinary mask): a short hole in the tracked frames
    /// shows the nearest tracked frame's matte (`filling`) instead of one frame without the mask.
    public func matte(key: String, pts: Double, feather: Double, expansion: Double, frameWidth: Double,
                      fills: Bool = false) -> SubjectMatte? {
        load(key)
        guard let (ek, f) = state.withLock({ s -> (EdgedKey, Frame)? in
            guard let list = s.frames[key] else { return nil }
            if fills { return edgedKey(key, list, pts, feather: feather, expansion: expansion, frameWidth: frameWidth) }
            return nearest(list, pts).map { (EdgedKey(key: key, pts: $0.pts, feather: feather, expansion: expansion, frameWidth: frameWidth), $0) }
        }) else { return nil }
        if let hit = state.withLock({ s -> SubjectMatte? in
            guard let i = s.lru.firstIndex(where: { $0.0 == ek }) else { return nil }
            let e = s.lru.remove(at: i); s.lru.append(e); return e.1
        }) { return hit }
        return make(ek, from: f)
    }

    /// `m` (tracked at `pts`) moved so that its center lies where the center line between `m` and `other` (tracked at
    /// `otherPts`) is at `gap`: a constant-speed subject keeps its place across a hole. Unchanged when either matte has
    /// no center (a lost frame) or the sizes differ.
    static func moved(_ m: SubjectMatte, from pts: Double, toward other: SubjectMatte, at otherPts: Double, gap: Double) -> SubjectMatte {
        guard m.width == other.width, m.height == other.height, otherPts != pts,
              let a = m.centroid, let b = other.centroid else { return m }
        let t = (gap - pts) / (otherPts - pts)
        return shifted(m, dx: (b.x - a.x) * t, dy: (b.y - a.y) * t)
    }

    /// `m` moved by (`dx`, `dy`) matte px (bilinear, zero beyond the edges).
    static func shifted(_ m: SubjectMatte, dx: Double, dy: Double) -> SubjectMatte {
        guard abs(dx) > 1e-6 || abs(dy) > 1e-6 else { return m }
        let w = m.width, h = m.height
        let ix = Int(dx.rounded(.down)), iy = Int(dy.rounded(.down))
        let fx = Float(dx - Double(ix)), fy = Float(dy - Double(iy))
        var out = [Float](repeating: 0, count: w * h)
        m.values.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                // out(x, y) = in(x - dx, y - dy): the four source texels at (x - ix - 1 ... x - ix), weights by the fraction.
                func at(_ x: Int, _ y: Int) -> Float { x < 0 || y < 0 || x >= w || y >= h ? 0 : src[y * w + x] }
                for y in 0 ..< h {
                    for x in 0 ..< w {
                        let sx = x - ix, sy = y - iy
                        let v = at(sx, sy) * (1 - fx) * (1 - fy) + at(sx - 1, sy) * fx * (1 - fy)
                            + at(sx, sy - 1) * (1 - fx) * fy + at(sx - 1, sy - 1) * fx * fy
                        dst[y * w + x] = v
                    }
                }
            }
        }
        return SubjectMatte(width: w, height: h, values: out)
    }

    /// Decodes and edges one stored frame and keeps it in the LRU.
    private func make(_ ek: EdgedKey, from f: Frame, inline: Bool = false) -> SubjectMatte? {
        guard var raw = Self.decode(f) else { return nil }
        if let toward = ek.toward, let gap = ek.gap {
            let other = state.withLock { s in s.frames[ek.key]?.first { abs($0.pts - toward) < 1e-6 } }
            if let other, let o = Self.decode(other) { raw = Self.moved(raw, from: f.pts, toward: o, at: other.pts, gap: gap) }
        }
        let scale = Double(raw.width) / max(ek.frameWidth, 1)
        let out = Self.edge(raw, feather: ek.feather * scale, expansion: ek.expansion * scale)
        state.withLock { s in
            s.decodes += 1
            if inline { s.inlineDecodes += 1 }
            // Stored again meanwhile (a track writes this frame): the new one is decoded when it is asked for.
            guard s.frames[ek.key]?.contains(where: { abs($0.pts - f.pts) < 1e-6 && $0.data == f.data }) ?? false,
                  !s.lru.contains(where: { $0.0 == ek }) else { return }
            s.lru.append((ek, out))
            s.trim(now: .now)
        }
        return out
    }

    /// Playback's read of an ordinary mask's matte on the render thread: the frame's own stored matte (across a real
    /// hole of at most `fillFrames` frames the nearer tracked one: `drawn`, the rule a paused frame draws by), from
    /// the LRU where the look-ahead (`prepare`) put it. When the look-ahead missed it (the first frame of a playback,
    /// a jump) it is decoded on the spot: a frame never shows a neighbor's matte in place of its own.
    func preparedMatte(key: String, pts: Double, feather: Double, expansion: Double, frameWidth: Double) -> SubjectMatte? {
        load(key)
        let found = state.withLock { s -> (hit: SubjectMatte?, ek: EdgedKey, frame: Frame)? in
            guard let list = s.frames[key],
                  let (ek, f) = edgedKey(key, list, pts, feather: feather, expansion: expansion, frameWidth: frameWidth) else { return nil }
            // A hit keeps its place: playback moves on, so the mattes made last (the frames ahead) are the ones to
            // keep, not the frame just shown.
            return (s.lru.first { $0.0 == ek }?.1, ek, f)
        }
        guard let found else { return nil }
        return found.hit ?? make(found.ek, from: found.frame, inline: true)
    }

    /// Playback look-ahead: the mattes the ordinary masks of `fx` draw at the coming source times `pts` (the frames
    /// the next ticks show, in playing order) are decoded and edged on the background queue, so the render thread
    /// finds them in the LRU (`mattes(playing:)`). A key whose file is not read yet is read there first. Each matte is
    /// made once. The LRU grows with what all playing masks ask for (`State.capacity`).
    public func prepare(for fx: ClipEffects, pts: [Double], frameWidth: Double) {
        let uses = fx.magicMattes.filter { !$0.mustCover && !$0.cacheKey.isEmpty }
        guard !uses.isEmpty, !pts.isEmpty else { return }
        let (todo, unread) = state.withLock { s -> ([(EdgedKey, Frame)], Bool) in
            var todo: [(EdgedKey, Frame)] = []
            var unread = false
            let now = ContinuousClock.now
            for m in uses {
                let use = EdgedKey(key: m.cacheKey, pts: 0, feather: m.feather, expansion: m.expansion, frameWidth: frameWidth)
                s.need[use] = (pts.count + 1 + Self.lookAheadMargin, now)
            }
            for t in pts {
                for m in uses {
                    guard s.loaded.contains(m.cacheKey) else { unread = true; continue }
                    guard let list = s.frames[m.cacheKey],
                          let (ek, f) = edgedKey(m.cacheKey, list, t, feather: m.feather, expansion: m.expansion, frameWidth: frameWidth)
                    else { continue }
                    guard !s.lru.contains(where: { $0.0 == ek }), s.preparing.insert(ek).inserted else { continue }
                    todo.append((ek, f))
                }
            }
            return (todo, unread)
        }
        guard !todo.isEmpty || unread else { return }
        ahead.async { [self] in
            for (ek, f) in todo {
                _ = make(ek, from: f)
                state.withLock { _ = $0.preparing.remove(ek) }
            }
            if unread {
                uses.forEach { load($0.cacheKey) }
                prepare(for: fx, pts: pts, frameWidth: frameWidth)
            }
        }
    }

    /// The edged mattes of every Magic mask `fx` evaluates, for the source frame at `pts` (`RenderLayer.mattes`). An
    /// ordinary mask not tracked at `pts` is left out (it covers nothing). A mask that must cover (made by Anonymize)
    /// always gets a matte (`covering`). `frameWidth`: the clip's upright frame width in px.
    /// - warped: the layer's source frame is warped before its effects (Gyroflow Stabilizer), so mattes tracked on the
    ///   file do not fit: a mask that must cover takes the whole frame.
    /// - still: the layer is a still image (one picture, no source time): `pts` is not read.
    /// - neighbors: source times of the other frames mixed into this one (frame blending, optical flow, temporal
    ///   denoise): a mask that must cover takes the union of all of them.
    /// - spanning: the mix moves the picture between the frames (optical flow): the box around all of them is covered.
    /// - wait: false on the render thread of playback. A cover then never reads a file and never grows a matte there:
    ///   until the background has it, the frame shows the whole-frame cover.
    /// - playing: the frame is one of a running playback: an ordinary mask reads what the look-ahead prepared
    ///   (`preparedMatte`) instead of decoding on this thread.
    public func mattes(for fx: ClipEffects, pts: Double, frameWidth: Double, warped: Bool = false, still: Bool = false,
                       neighbors: [Double] = [], spanning: Bool = false, wait: Bool = true,
                       playing: Bool = false) -> [UUID: SubjectMatte] {
        var out: [UUID: SubjectMatte] = [:]
        for m in fx.magicMattes {
            if m.mustCover {
                out[m.mask] = covering(m, pts: pts, frameWidth: frameWidth, warped: warped, still: still,
                                       neighbors: neighbors, spanning: spanning, wait: wait)
            } else if !still, !m.cacheKey.isEmpty {
                out[m.mask] = playing
                    ? preparedMatte(key: m.cacheKey, pts: pts, feather: m.feather, expansion: m.expansion, frameWidth: frameWidth)
                    : matte(key: m.cacheKey, pts: pts, feather: m.feather, expansion: m.expansion, frameWidth: frameWidth, fills: true)
            }
        }
        return out
    }

    /// What a mask that must cover draws: its matte where every frame in the mix has one, a larger estimate where not,
    /// the whole frame when nothing can be said (or not yet). Never nothing.
    func covering(_ m: MagicMatteUse, pts: Double, frameWidth: Double, warped: Bool = false, still: Bool = false,
                  neighbors: [Double] = [], spanning: Bool = false, wait: Bool = true) -> SubjectMatte {
        let whole = AnonymizeFallback.wholeFrame
        guard !warped, !m.cacheKey.isEmpty else { return whole }
        let keys = [m.cacheKey] + (m.baseKey.map { [$0] } ?? [])
        if !wait, !keys.allSatisfy(isLoaded) {
            preloadSoon(keys)
            return whole
        }
        if still {
            // One picture: whatever was tracked on it is its matte (the part first, else the whole person).
            for k in keys {
                load(k)
                if let t = state.withLock({ $0.frames[k]?.first?.pts }),
                   let x = matte(key: k, pts: t, feather: m.feather, expansion: m.expansion, frameWidth: frameWidth) { return x }
            }
            return whole
        }
        if !wait { warmCovers(m, around: pts, frameWidth: frameWidth) }
        var parts: [SubjectMatte] = []
        for t in [pts] + neighbors {
            if let x = matte(key: m.cacheKey, pts: t, feather: m.feather, expansion: m.expansion, frameWidth: frameWidth) {
                parts.append(x)
            } else if let x = cover(m, pts: t, frameWidth: frameWidth, wait: wait) {
                parts.append(x)
            } else {
                return whole
            }
        }
        return parts.count == 1 ? parts[0] : Self.union(parts, spanning: spanning)
    }

    /// What a mask that must cover draws on a frame without its own matte (the person was lost, a trim or slip revealed
    /// the frame after the run, the file is gone): the followed whole person of that frame when it is stored, else the
    /// nearest tracked matte grown by `AnonymizeFallback.growth`, else the whole frame. nil only with `wait` false: the
    /// grown matte is being made in the background (the caller shows the whole frame meanwhile).
    func cover(_ m: MagicMatteUse, pts: Double, frameWidth: Double, wait: Bool = true) -> SubjectMatte? {
        if let base = m.baseKey,
           let x = matte(key: base, pts: pts, feather: m.feather, expansion: m.expansion, frameWidth: frameWidth) { return x }
        guard let best = coverSource(m, pts: pts) else { return AnonymizeFallback.wholeFrame }
        let ek = grownKey(m, source: best, growth: AnonymizeFallback.growth(gap: abs(best.pts - pts)), frameWidth: frameWidth)
        // A hit stays wanted as long as the frame is drawn again: a paused frame whose batch took longer than the window
        // must not see the mattes it already got evicted by the ones that came later (a rebuild, then a redraw).
        if let hit = state.withLock({ s -> SubjectMatte? in
            guard let g = s.grown[ek] else { return nil }
            if !wait { s.wanted[ek] = .now }
            return g
        }) { return hit }
        if wait { return makeGrown(ek) ?? AnonymizeFallback.wholeFrame }
        state.withLock { $0.wanted[ek] = .now }
        schedule([ek])
        return nil
    }

    /// The tracked frame nearest to `pts` among the mask's keys. The whole person is asked first and wins a tie: it
    /// covers more.
    private func coverSource(_ m: MagicMatteUse, pts: Double) -> (key: String, pts: Double)? {
        var best: (key: String, pts: Double)?
        for k in [m.baseKey, m.cacheKey].compactMap({ $0 }) {
            load(k)
            let near = state.withLock { s in (s.frames[k] ?? []).min { abs($0.pts - pts) < abs($1.pts - pts) }?.pts }
            if let near, best.map({ abs(near - pts) < abs($0.pts - pts) - 1e-6 }) ?? true { best = (k, near) }
        }
        return best
    }

    private func grownKey(_ m: MagicMatteUse, source: (key: String, pts: Double), growth: Double, frameWidth: Double) -> EdgedKey {
        EdgedKey(key: source.key, pts: source.pts, feather: m.feather, expansion: m.expansion + growth * frameWidth, frameWidth: frameWidth)
    }

    /// Decodes and grows one stored frame and keeps it. nil when the frame is gone.
    @discardableResult
    private func makeGrown(_ ek: EdgedKey) -> SubjectMatte? { makeGrownReporting(ek).matte }

    /// `fresh`: the matte was not kept before (something new became available).
    private func makeGrownReporting(_ ek: EdgedKey) -> (matte: SubjectMatte?, fresh: Bool) {
        let stored = state.withLock { s in s.frames[ek.key]?.first { abs($0.pts - ek.pts) < 1e-6 } }
        guard let f = stored, let raw = Self.decode(f) else {
            if stored != nil { state.withLock { _ = $0.failed.insert(ek) } }
            return (nil, false)
        }
        let scale = Double(raw.width) / max(ek.frameWidth, 1)
        let out = Self.edge(raw, feather: ek.feather * scale, expansion: ek.expansion * scale)
        let fresh = state.withLock { s -> Bool in
            s.decodes += 1
            let now = ContinuousClock.now
            guard s.grown[ek] == nil else { return false }
            // Evict the oldest entry the shown frame does not ask for; the cache grows past capacity before it drops one.
            if s.grownOrder.count >= Self.grownCapacity, let i = s.grownOrder.firstIndex(where: { !s.isWanted($0, now: now) }) {
                s.grown[s.grownOrder.remove(at: i)] = nil
            }
            s.grown[ek] = out
            s.grownOrder.append(ek)
            return true
        }
        return (out, fresh)
    }

    /// Test hook: how long a grown matte counts as asked for after the shown frame asked.
    func setWantedWindow(_ d: Duration) { state.withLock { $0.wantedWindow = d } }

    /// Makes the grown mattes `keys` in the background, each once; observers hear when they are there.
    private func schedule(_ keys: [EdgedKey]) {
        let todo = state.withLock { s in
            keys.filter { s.grown[$0] == nil && !s.failed.contains($0) && s.pending.insert($0).inserted }
        }
        guard !todo.isEmpty else { return }
        work.async { [self] in
            var news = false
            for ek in todo {
                // The queue can outlast the window: what the shown frame asked for (still within it) stays wanted while
                // the mattes of the same frame are made, so the first ones are not evicted by the last.
                state.withLock { s in
                    let now = ContinuousClock.now
                    for (k, _) in s.wanted where s.isWanted(k, now: now) { s.wanted[k] = now }
                }
                if makeGrownReporting(ek).fresh { news = true }
                state.withLock { _ = $0.pending.remove(ek) }
            }
            if news { notifyReady() }
        }
    }

    /// Playback: when the tracking ends within `warmReach` of `pts` (before or after), the grown mattes of that gap are
    /// made now, so the first frame inside it already has one.
    private func warmCovers(_ m: MagicMatteUse, around pts: Double, frameWidth: Double) {
        var keys: [EdgedKey] = []
        for t in [pts - Self.warmReach, pts + Self.warmReach] {
            let tracked = state.withLock { s in
                [m.cacheKey, m.baseKey].contains { k in k.flatMap { s.frames[$0] }.flatMap { nearest($0, t) } != nil }
            }
            guard !tracked, let src = coverSource(m, pts: t) else { continue }
            for g in AnonymizeFallback.growths { keys.append(grownKey(m, source: src, growth: g, frameWidth: frameWidth)) }
        }
        state.withLock { s in
            let now = ContinuousClock.now
            s.wanted = s.wanted.filter { s.isWanted($0.key, now: now) }
            for k in keys { s.wanted[k] = now }
        }
        if !keys.isEmpty { schedule(keys) }
    }

    /// The largest of `parts` per pixel (at the size of the largest part). `spanning`: the box around everything they
    /// cover is filled as well.
    static func union(_ parts: [SubjectMatte], spanning: Bool) -> SubjectMatte {
        let whole = AnonymizeFallback.wholeFrame
        guard let big = parts.max(by: { $0.width * $0.height < $1.width * $1.height }), !parts.contains(whole) else { return whole }
        let w = big.width, h = big.height
        var v = [Float](repeating: 0, count: w * h)
        for p in parts {
            if p.width == w, p.height == h {
                v = vDSP.maximum(v, p.values)
            } else {
                for y in 0..<h {
                    let sy = min(p.height - 1, y * p.height / h)
                    for x in 0..<w { v[y * w + x] = max(v[y * w + x], p[min(p.width - 1, x * p.width / w), sy]) }
                }
            }
        }
        if spanning {
            var x0 = w, x1 = -1, y0 = h, y1 = -1
            for y in 0..<h {
                for x in 0..<w where v[y * w + x] > 0.02 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
            if x1 >= x0 { for y in y0...y1 { for x in x0...x1 { v[y * w + x] = 1 } } }
        }
        return SubjectMatte(width: w, height: h, values: v)
    }

    /// Frames of `tl` that export would draw with an untracked Magic mask (enabled, picked, cutting the picture or feeding
    /// an effect, no matte drawn at that source frame: `drawn`, so a short hole that is filled does not count), nested
    /// sequences (`sequences`) included. Export warns before it starts; those frames show no mask.
    /// The times asked are the timeline's (`sourceInstant`), not the file's frame times: on media with a frame held much
    /// longer than its neighbors (variable frame rate) a time inside such a frame counts as untracked here, while
    /// export itself asks with the decoded frame's time and finds the matte (`missesMatte`).
    public func untrackedFrames(in tl: Timeline, sequences: [Timeline.ID: Timeline] = [:]) -> Int {
        let needs = tl.magicMatteNeeds(sequences: sequences)
        guard !needs.isEmpty else { return 0 }
        let keys = Set(needs.flatMap { $0.map(\.key) })
        keys.forEach(load)
        let lists = state.withLock { s in Dictionary(uniqueKeysWithValues: keys.map { ($0, s.frames[$0] ?? []) }) }
        return needs.filter { frame in frame.contains { drawn(lists[$0.key] ?? [], $0.pts) == nil } }.count
    }

    /// True when some Magic mask of `fx` has no tracked matte at `pts` (export warns: the mask is not tracked there).
    public func missesMatte(for fx: ClipEffects, pts: Double) -> Bool {
        fx.magicMattes.contains { m in
            load(m.cacheKey)
            return state.withLock { s in s.frames[m.cacheKey].flatMap { drawn($0, pts) } } == nil
        }
    }

    static func decode(_ f: Frame) -> SubjectMatte? {
        let n = f.width * f.height
        let raw: Data
        if f.data.count == n { raw = f.data }
        else if let d = try? (f.data as NSData).decompressed(using: .lzfse) as Data, d.count == n { raw = d }
        else { return nil }
        var v = [Float](repeating: 0, count: n)
        var bytes = [UInt8](raw)
        bytes.withUnsafeMutableBytes { s in
            v.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: 1, width: vImagePixelCount(n), rowBytes: n)
                var dst = vImage_Buffer(data: d.baseAddress, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                _ = vImageConvert_Planar8toPlanarF(&src, &dst, 1, 0, vImage_Flags(kvImageNoFlags))
            }
        }
        return SubjectMatte(width: f.width, height: f.height, values: v)
    }

    // MARK: Files

    private func file(_ key: String) -> URL? { directory?.appendingPathComponent("\(key).sqmatte") }

    /// Reads a key's file once (later puts stay in memory until `save`).
    private func load(_ key: String) {
        guard state.withLock({ !$0.loaded.contains(key) }) else { return }
        var frames: [Frame] = []
        if let url = file(key), let data = try? Data(contentsOf: url) { frames = Self.parse(data) }
        state.withLock { s in
            guard !s.loaded.contains(key) else { return }
            s.loaded.insert(key)
            let mem = s.frames[key] ?? []
            var all = frames.filter { f in !mem.contains { abs($0.pts - f.pts) < 1e-6 } } + mem
            all.sort { $0.pts < $1.pts }
            s.frames[key] = all
        }
    }

    /// Writes a key's frames to its file.
    public func save(key: String) {
        guard let url = file(key) else { return }
        // One writer at a time, each reading the frames inside the lock: the write that runs last has the newest state.
        saveLock.withLock { _ in write(key, to: url) }
    }

    private let saveLock = Mutex(())
    /// Saves asked for from the main thread (`saveLater`), one after the other.
    private let saves = DispatchQueue(label: "sq.magic-matte.save", qos: .utility)

    /// Writes a key's frames to its file off the calling thread, after the saves queued before it. The write reads
    /// the frames when it runs, so it never puts an older state over one a run saved meanwhile. `waitForSaves`
    /// before the process exits.
    public func saveLater(key: String) {
        guard directory != nil, state.withLock({ $0.queued.insert(key).inserted }) else { return }
        saves.async { [self] in
            state.withLock { _ = $0.queued.remove(key) }
            save(key: key)
        }
    }

    /// Returns when every save queued so far is in its file (quit; tests).
    public func waitForSaves() { saves.sync {} }

    /// Keys whose frames in memory are not in their file.
    public var unsavedKeys: Set<String> { state.withLock { $0.unsaved } }

    /// Queues a save for every key of `keys` whose frames in memory are not in its file and that has no save waiting:
    /// a run stopped because its mask was removed saves nothing, and the mask can come back (undo). Returns those keys.
    @discardableResult
    public func saveUnsaved(among keys: Set<String>) -> [String] {
        let todo = state.withLock { $0.unsaved.intersection(keys).subtracting($0.queued) }.sorted()
        for key in todo { saveLater(key: key) }
        return todo
    }

    /// Keeps the queued saves waiting until `gate` is signaled (tests).
    func holdSaves(until gate: DispatchSemaphore) { saves.async { gate.wait() } }
    /// The last keys written, oldest first (tests).
    var savedOrder: [String] { state.withLock { $0.saveLog } }

    private func write(_ key: String, to url: URL) {
        let frames = state.withLock { s -> [Frame]? in
            guard !s.removed.contains(key) else { return nil }
            s.unsaved.remove(key)
            s.saveLog.append(key)
            if s.saveLog.count > 32 { s.saveLog.removeFirst(s.saveLog.count - 32) }
            return s.frames[key] ?? []
        }
        guard let list = frames else { return }
        var out = Data("SQMT".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }
        put(Self.fileVersion); put(UInt32(list.count))
        for f in list {
            put(f.pts); put(UInt32(f.width)); put(UInt32(f.height)); put(UInt32(f.data.count))
            out.append(f.data)
        }
        try? out.write(to: url, options: .atomic)
    }

    static func parse(_ d: Data) -> [Frame] {
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
            out.append(Frame(pts: pts, width: Int(w), height: Int(h), data: d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + Int(n)))))
            i += Int(n)
        }
        return out
    }

    /// The mask's edge on a matte through the shared SQCore `MatteRefine` (the keyers' Shrink/Feather): positive `expansion`
    /// grows the subject, `feather` is the soft edge width (box radius feather/2), both in matte px.
    static func edge(_ m: SubjectMatte, feather: Double, expansion: Double) -> SubjectMatte {
        let refine = MatteRefine(feather: feather / 2, shrinkPx: -expansion)
        guard !refine.isSpatialIdentity else { return m }
        return SubjectMatte(width: m.width, height: m.height, values: refine.refine(m.values, width: m.width, height: m.height))
    }

    /// Copies the frames of `from` whose time passes `keep` to `to` (replacing frames there at the same times): a corrected
    /// pick keeps the tracked frames the correction does not change.
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
            s.written.insert(to)
            s.touch(to)
            s.forget(to)
            return moved.count
        }
    }

    /// Forgets a key (memory and file): Track again from scratch.
    /// The key refuses saves from here on until it gets frames again. Its frames are gone when this returns; its file
    /// is removed on the save queue, behind the saves queued and a write that is running, so the caller (the main
    /// thread: Delete Mask, a correction, the sweep at project close) never waits for a write. `waitForSaves` waits
    /// for it too.
    public func remove(key: String) {
        state.withLock { s in
            s.frames[key] = nil; s.loaded.insert(key); s.forget(key)
            s.unsaved.remove(key); s.removed.insert(key)
        }
        guard let url = file(key) else { return }
        saves.async { [self] in
            saveLock.withLock { _ in
                // Frames again meanwhile (the same pick made again): the file is theirs, not the removed ones'.
                if state.withLock({ $0.removed.contains(key) }) { try? FileManager.default.removeItem(at: url) }
                else { write(key, to: url) }
            }
        }
    }

    /// Holds the write lock on another thread until `gate` is signaled, as a slow write does (tests). `started` is
    /// signaled once it is held.
    func holdWrite(started: DispatchSemaphore, until gate: DispatchSemaphore) {
        DispatchQueue.global().async { [self] in saveLock.withLock { _ in started.signal(); gate.wait() } }
    }
}

/// The last part of a tracked frame (its edge step and its store write) on a queue of its own, while the frame lane
/// already gives the next frame to the model: the edge step is CPU work, the model runs on the GPU / Neural Engine.
/// At most `depth` frames wait (each holds its picture); `drain` waits for all of them. Jobs run one at a time, in order.
final class MatteFinisher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sq.matte-finisher", qos: .userInitiated)
    private let room: DispatchSemaphore

    init(depth: Int = 2) { room = DispatchSemaphore(value: depth) }

    /// Runs `job` after the jobs before it; waits first while `depth` jobs are waiting.
    func submit(_ job: @escaping @Sendable () -> Void) {
        room.wait()
        queue.async { [room] in
            job()
            room.signal()
        }
    }

    /// Returns once every submitted job has run.
    func drain() { queue.sync {} }
}

/// A frame's picture handed to the finishing queue: the lane does not touch it after handing it on.
struct SentPicture: @unchecked Sendable { let buffer: CVPixelBuffer }

/// Track for a Magic mask: reads the source from `from` to the clip edge (forward or backward), segments each frame and
/// stores the followed matte per frame under `key`. Stops at the first frame the subject is lost (returns how far it got).
public struct MagicMaskTracker: Sendable {
    public let url: URL
    public let maxDimension: Int
    public let chunkSeconds: Double
    public let segmenter: any InstanceSegmenting
    /// Seconds without a frame after which a track's read counts as hung and ends (`FrameReader.stallAfter`).
    var stallAfter: Double = WorkLimits.frameWorkStallSeconds
    /// Shape of the media's stored pixels (`VideoTrackInfo.displayPixelAspect`): the frames are analyzed as shown.
    public let pixelAspect: PixelAspect
    /// The media item's `VideoTrackInfo.deinterlaceFieldOrder`: hover, pick and track see the frames deinterlaced, as
    /// the monitor shows them (nil = as stored).
    public let deinterlace: FieldOrder?

    /// The tracking model's owner, nil = the system's segmentation only. Every run asks it for the model when it
    /// begins (`SubjectMaskEngine.leaseForRun`).
    let engine: SubjectMaskEngine?
    /// Seconds a run waits for a model that is loading before it tracks with the system's segmentation.
    var loadWait: Double = SubjectMaskEngine.loadWaitSeconds
    /// How the edge of a tracked matte is made (`SubjectMaskQuality`), for every run of this tracker: a pick's legs
    /// (forward, backward, each range) share one tracker, so they share one edge. Speed unless the caller says
    /// otherwise; the app passes the user's setting through `decide`. Hover and pick always work at the tracking size.
    public var quality = SubjectMaskQuality.speed

    /// Settles the edge for this tracker's runs, once, before the first: `wanted`, but Speed while memory is short
    /// (`SubjectMaskEngine.hasRoomForQuality`) or the edge step is off. What memory does later does not change it:
    /// a shot's frames keep one edge and one size.
    public mutating func decide(_ wanted: SubjectMaskQuality) {
        let room = engine?.hasRoomForQuality ?? true
        quality = wanted == .quality && SubjectMatteEdges.enabled && room ? .quality : .speed
    }

    /// Seconds of frames a backward run holds at once. Frames `frame` px long instead of `analysis` take
    /// (frame / analysis)^2 the memory, so the chunk is that much shorter, but not under a quarter second (every chunk
    /// is a read of its own that decodes from the key frame before it). On the standard profile (960 px, a second) the
    /// held frames take what the tracking size took; on the small one (540 px, half a second) the floor leaves twice
    /// that, about 40 MB at 60 fps.
    static func backwardChunkSeconds(_ seconds: Double, analysis: Int, frame: Int) -> Double {
        guard frame > analysis, analysis > 0 else { return seconds }
        let ratio = Double(analysis) / Double(frame)
        return min(seconds, max(seconds * ratio * ratio, 0.25))
    }

    /// `engine` nil: the app's (`SubjectMaskEngine.shared`) with the system's segmenter, none with another one.
    public init(url: URL, limits: WorkLimits = .current, segmenter: any InstanceSegmenting = VisionInstanceSegmenter(),
                pixelAspect: PixelAspect = .square, deinterlace: FieldOrder? = nil, engine: SubjectMaskEngine? = nil) {
        self.url = url; maxDimension = limits.subjectMaskDimension; chunkSeconds = limits.maskTrackChunkSeconds
        self.segmenter = segmenter; self.pixelAspect = pixelAspect; self.deinterlace = deinterlace
        self.engine = engine ?? (segmenter is VisionInstanceSegmenter ? .shared : nil)
    }

    public struct Result: Sendable {
        /// Frames the subject was followed on (stored with its matte).
        public var frames: Int
        /// Source time (s) of the last frame the subject was followed on, nil when on none.
        public var lastTime: Double?
        /// Source times (s) of the frames the subject was not found on, in tracking order. The track went on past them.
        public var lostTimes: [Double] = []
        /// The subject was not found on some frame of the range.
        public var lost: Bool { !lostTimes.isEmpty }
    }

    /// What a frame without the subject is stored as: an empty matte, so the frame counts as tracked (nothing of the
    /// picture is in the mask there) and the health strip shows it weak.
    public static let lostMatte = SubjectMatte(width: 1, height: 1, values: [0])

    /// The objects of the source frame at `seconds` (hover highlight and picking in the Program monitor), with that frame's
    /// pts (the time its matte is stored at). nil = nothing segmented on that frame. A read that hands out no frame is
    /// an error (`SubjectFrameError.noFrame`), not "nothing here". The read and the Vision request block: they run on
    /// `SubjectFrameWorker`'s thread, not on the cooperative pool (WebM: its decoder's own path).
    public func segment(at seconds: Double) async throws -> (frame: InstanceFrame, pts: Double)? {
        // The mask tool's first look at a frame: the tracking model starts loading in the background.
        engine?.prewarm()
        var shaped = FrameReader(url: url, maxDimension: maxDimension, deinterlace: deinterlace)
        shaped.pixelAspect = pixelAspect
        let reader = shaped
        if reader.isWebM {
            guard let (pb, pts) = try await reader.shownWebM(at: seconds) else { throw SubjectFrameError.noFrame(seconds) }
            nonisolated(unsafe) let frame = pb
            let segmenter = segmenter
            return try await SubjectFrameWorker.shared.run { try segmenter.segment(frame).map { (frame: $0, pts: pts) } }
        }
        let plan = try await reader.plan()
        let segmenter = segmenter
        let hooks = FrameReader.Hooks.current
        // A request given up (a newer frame, the session's deadline) cancels this task: the reader is canceled with it,
        // so a read that hangs in the decoder ends and gives its thread back.
        return try await withTaskCancellationHandler {
            try await SubjectFrameWorker.shared.run {
                // The frame the monitor shows (pts <= seconds < next pts). Only it is shrunk, not every frame read to
                // find it.
                guard let (pb, pts) = try reader.shown(plan, at: seconds, hooks: hooks) else {
                    throw SubjectFrameError.noFrame(seconds)
                }
                return try segmenter.segment(pb).map { (frame: $0, pts: pts) }
            }
        } onCancel: { reader.stop.stop() }
    }

    /// A frame request never came back (the session gave it up at its deadline) and the user clicks to try again:
    /// later requests run on a fresh thread instead of waiting behind the one that hangs.
    public static func abandonStuckFrameWork() {
        NSLog("[Magic] frame work: going on with a fresh thread")
        SubjectFrameWorker.replace()
    }

    /// The matte of `points` on an already segmented frame; nil when they leave nothing. Makes soft mattes (a Vision
    /// call): not for the main thread.
    public static func pickMatte(_ f: InstanceFrame, pts: Double, points: [MagicPoint], start: SubjectMatte? = nil,
                                 span: Double = 0) -> SubjectMatte? {
        // A mid-clip click (`start`: the tracked matte of this frame): a mask that already answers the clicks made on
        // the frame stays (`SubjectCorrectionRule`, as in the tracking leg), else the pick below refines it.
        if let start, !start.isBlank {
            let here = points.filter {
                MagicFollower.belongs(point: Double($0.sourceTime.value) / Double(max($0.sourceTime.timescale, 1)), pts: pts, span: span)
            }
            if SubjectCorrectionRule.answers(here, matte: start) { return start }
        }
        var follower = MagicFollower(start: start)
        return follower.step(f, points: points, pts: pts, span: span).map { SubjectMatteCore.solid($0) }
    }

    /// Stores the matte of `points` on an already segmented frame (a click's immediate result, before Track). `start`: the
    /// tracked matte of this frame before a correction made on it (a click on another frame than the pick's); the points
    /// made on this frame (`pts`, shown for `span` seconds) then correct it.
    public static func pick(_ f: InstanceFrame, pts: Double, key: String, points: [MagicPoint], store: MagicMatteStore,
                            start: SubjectMatte? = nil, span: Double = 0) -> Bool {
        guard let m = pickMatte(f, pts: pts, points: points, start: start, span: span) else { return false }   // nothing found: no matte
        store.put(m, key: key, pts: pts)
        store.save(key: key)
        return true
    }

    /// `from`/`to`: source seconds, `to` < `from` runs backward. `points`: the clicks of the pick.
    /// `key` holds the followed matte, which is what a later Track continues from. `refine` with `refinedKey` (F7.11
    /// Anonymize, Face / Skin): each followed matte is also narrowed and the narrowed one stored under `refinedKey`.
    ///
    /// A frame the subject is not found on (hidden, out of the picture, the segmenter sees nothing) does not end the
    /// track: it is stored empty (`lostMatte`, `Result.lostTimes`) and the next frames are compared with the last matte
    /// that was found. `marksLost` false (a mask that must cover, Anonymize): nothing is stored for such a frame, so
    /// its lookup falls back to the enlarged cover of the last place instead of showing the person. Only a track with
    /// nothing to follow on its first frame ends there (`frames` 0).
    ///
    /// `preparing`: true when the run waits for the tracking model to load (worth a status line), false when the
    /// wait ended and the frames start. Never called when there is nothing to wait for.
    public func track(key: String, points: [MagicPoint], from: Double, to: Double, store: MagicMatteStore,
                      refinedKey: String? = nil, refine: (@Sendable (CVPixelBuffer, Double, SubjectMatte) throws -> SubjectMatte)? = nil,
                      marksLost: Bool = true, keep: (@Sendable () -> Bool)? = nil,
                      preparing: (@Sendable (Bool) -> Void)? = nil,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> Result {
        let forward = to >= from
        let began = SubjectMaskTiming.now()
        // Stopped or lost: the frames done so far are kept. `keep` false at the end (the mask was removed meanwhile):
        // its file is not written again.
        defer {
            if keep?() ?? true {
                store.save(key: key)
                if let refinedKey { store.save(key: refinedKey) }
            }
        }
        var follower = MagicFollower(start: store.matte(key: key, pts: from))
        var res = Result(frames: 0, lastTime: nil)
        let span = max(abs(to - from), 1e-3)
        // `gap`: seconds to the next frame of the file; a point stored inside it (the playhead's time) was made on this frame.
        // The tracking model carries the leg when the engine has it or gets it loaded in time (the first use, the
        // reload after a failure: the run waits, the user's Stop cancels the wait); a mask that must cover
        // (Anonymize) stays on the system's segmentation. Whatever fails on the model, the leg goes on with the
        // system's segmentation from the last matte that was found.
        var asked: SubjectMaskEngine.Lease?
        if refinedKey == nil, marksLost, let engine {
            let waited = SubjectMaskTiming.now()
            asked = try await engine.leaseForRun(wait: loadWait, preparing: preparing)
            SubjectMaskTiming.count("lease_wait", since: waited)
        }
        let lease = asked
        defer { if lease != nil { engine?.end() } }
        var leg = lease.flatMap { SubjectTrackLeg(lease: $0, segmenter: TimedSegmenter(segmenter)) }
        // Quality: only a run on the model reads larger frames (the model's mask is what the edge step refines).
        // The choice was settled before the pick's first run (`decide`) and holds to the end of this one.
        // A leg that gets no model (taken away between the forward and the backward leg, or failed) reads at the
        // tracking size like every run on the system's segmentation: its mattes are smaller than the other leg's.
        // The store keeps a size per matte and every reader takes them mixed, so the frame size is not forced here
        // (the system's segmentation would only get slower from frames twice as long).
        let fine = leg != nil && quality == .quality && SubjectMatteEdges.enabled
        if fine { leg?.quality = .quality }
        // The model's mattes get their edge step and their store write on `finisher` while the lane goes on with the
        // next frame (same mattes, about a third less time per frame). `lastFound` then stays without the edge step:
        // only the system's segmentation starts from it, after the model failed.
        let finisher = MatteFinisher()
        leg?.defersEdges = true
        let edger = leg?.edger
        // Runs before the save above: every matte of the run is in the store when it is written.
        defer { finisher.drain() }
        let frameDimension = fine ? quality.frameDimension(analysis: maxDimension) : maxDimension
        let chunkSeconds = Self.backwardChunkSeconds(chunkSeconds, analysis: maxDimension, frame: frameDimension)
        var reader = FrameReader(url: url, maxDimension: frameDimension, deinterlace: deinterlace)
        reader.stallAfter = stallAfter
        reader.pixelAspect = pixelAspect
        // `step` runs on the frame lane's thread inside `forEach`: the reader's stop is its cancellation there.
        let stop = reader.stop
        // Set while a frame is with the model (its predictions only): a read the lane then calls hung was hung in
        // the model.
        let inModel = leg?.inModel
        // Frames the model answered (found or lost) in this run.
        var modelFrames = 0
        // Between two frames of the lane (the reader's decode and scale): stage `read`.
        var stepEnded: UInt64 = 0
        func step(_ pb: CVPixelBuffer, _ pts: Double, _ gap: Double) throws -> Bool {
            if stepEnded > 0 { SubjectMaskTiming.count("read", since: stepEnded) }
            defer { stepEnded = SubjectMaskTiming.now() }
            try stop.check()
            var answer: SubjectTrackLeg.Answer?
            var needsEdge = false
            if let l = leg {
                do {
                    // The stored matte is decoded only when the leg asks for it (first frame, frames with points).
                    let began = DispatchTime.now().uptimeNanoseconds
                    let given = try l.step(pb, pts: pts, gap: gap, points: points) { store.matte(key: key, pts: pts) }
                    SubjectMaskTiming.count(modelFrames == 0 ? "leg_first" : "leg_step", since: began)
                    if case .nothing = given {} else { modelFrames += 1 }
                    answer = given
                    needsEdge = l.answerNeedsEdge
                } catch let canceled as CancellationError {
                    throw canceled
                } catch {
                    // Only the model's own failures count against it; a matte too faint to start from or an error of
                    // the system's segmentation just ends the model's part of this run.
                    if let lease, (error as? SubjectTrackError)?.isModelFailure == true { engine?.failed(lease, error: error) }
                    NSLog("[SubjectMask] this track goes on with Vision from %.3f s (%@)", pts, "\(error)")
                    if let last = l.lastFound { follower = MagicFollower(start: last) }
                    leg = nil
                }
            }
            if answer == nil {
                if let f = try SubjectMaskTiming.measure("vision", { try segmenter.segment(pb) }),
                   let m = SubjectMaskTiming.measure("follow", { follower.step(f, points: points, pts: pts, span: gap) }) {
                    answer = .found(SubjectMatteCore.solid(m))
                } else {
                    // Nothing found before either: there is no subject to look for on the next frames.
                    answer = follower.previous != nil ? .lost : .nothing
                }
            }
            guard case .found(let m) = answer else {
                guard case .lost = answer else { return false }
                try stop.check()
                res.lostTimes.append(pts)
                if marksLost, refinedKey == nil { store.putLost(key: key, pts: pts) }
                progress?(min(abs(pts - from) / span, 1))
                return true
            }
            let refined = refinedKey == nil ? nil : try refine?(pb, pts, m)
            // Stopped while this frame was segmented or narrowed (Stop, or its mask was removed): nothing more is
            // written, neither the followed matte nor the narrowed one.
            try stop.check()
            if needsEdge, let edger {
                // A leg only runs without a narrowed key (`refinedKey` nil), so there is no narrowed matte here.
                let picture = SentPicture(buffer: pb)
                finisher.submit {
                    let edged = edger.edged(m, picture.buffer)
                    let began = DispatchTime.now().uptimeNanoseconds
                    store.put(edged, key: key, pts: pts)
                    SubjectMaskTiming.count("store_put", since: began)
                }
            } else {
                // Behind the deferred frames, so a frame stored twice (a correction) keeps the last write.
                finisher.drain()
                let began = DispatchTime.now().uptimeNanoseconds
                store.put(m, key: key, pts: pts)
                if let refined, let refinedKey { store.put(refined, key: refinedKey, pts: pts) }
                SubjectMaskTiming.count("store_put", since: began)
            }
            res.frames += 1; res.lastTime = pts
            progress?(min(abs(pts - from) / span, 1))
            return true
        }
        do {
        if forward {
            // One frame behind the reader, so every frame knows how long it is shown (the last one: like the one before).
            var held: (CVPixelBuffer, Double)?
            var gap = 0.0
            var going = true
            try await reader.forEach(from: from, to: to) { pb, pts in
                if let h = held {
                    gap = max(pts - h.1, 0)
                    leg?.lookAhead(pb)   // the model encodes this frame while it answers the one before
                    going = try step(h.0, h.1, gap)
                }
                held = (pb, pts)
                return going
            }
            // The last frame is segmented after the read ended: on the lane as well, not on the cooperative pool.
            if going, let h = held { try await reader.work { _ = try step(h.0, h.1, gap) } }
        } else {
            var end = from
            var chunkEnd = from + 1e-3
            var gap = 0.0
            outer: while true {
                let a = max(to, end - chunkSeconds)
                var frames: [(CVPixelBuffer, Double)] = []
                // A chunk that does not end the run leaves the frame at its very start to the next one: the reader
                // gives the frame on screen there the start as its pts (`FrameReader.shown`), which is that frame's
                // own time only when the start falls on a frame. Taken here, a frame was followed and stored twice,
                // once at a time no frame has.
                let first = a > to ? a + 2e-4 : -.infinity
                try await reader.forEach(from: a, to: end) { pb, pts in
                    if pts < chunkEnd - 1e-6, pts > first { frames.append((pb, pts)) }
                    return true
                }
                // The frame after the start frame is not read: the start frame takes the spacing of the frames before it.
                if gap == 0, frames.count > 1 { gap = frames[frames.count - 1].1 - frames[frames.count - 2].1 }
                var going = true
                try await reader.work {
                    for (i, (pb, pts)) in frames.enumerated().reversed() where going {
                        if i + 1 < frames.count { gap = frames[i + 1].1 - pts }
                        if i > 0 { leg?.lookAhead(frames[i - 1].0) }
                        going = try step(pb, pts, gap)
                    }
                }
                if !going { break outer }
                guard a > to else { break }
                // No frame in this chunk (frames further apart than a chunk is long: a low frame rate, a screen
                // recording, dropped frames): the run goes on with the chunk before it.
                if let earliest = frames.first?.1 { chunkEnd = earliest }
                end = a
            }
        }
        } catch let stalled as BlockingLane.Stalled {
            // Hung inside the model: that model is abandoned, so the next pick does not wait behind it.
            if let lease, inModel?.isSet == true { engine?.failed(lease, error: SubjectTrackError.stalled) }
            throw stalled
        }
        // The model carried the run to its end and answered frames on the way: earlier failures are forgotten. A run
        // with nothing to follow proves nothing about the model.
        if let lease, leg != nil, modelFrames > 0 { engine?.succeeded(lease) }
        finisher.drain()
        SubjectMaskTiming.report("track \(forward ? "forward" : "backward") \(quality.rawValue)\(leg == nil ? " (Vision)" : "")", since: began, frames: res.frames)
        progress?(1)
        return res
    }
}
