import CoreVideo
import Darwin
import Foundation
import SQCore
import Synchronization

// Gyroflow engine (DECISIONS 2026-10-06, docs/GYROFLOW.md): gyroflow_core (GPL-3.0, Rust) behind the `sqgyro` C shim
// (Vendor/sqgyro), built by scripts/build-gyro.sh as libsqgyro.dylib and loaded here at runtime. The app builds without
// Rust; without the library the Gyroflow method stays grayed with `missingReason`.
//
// One analysis per (file, options): open (reads the gyro data, lens profile) and smoothing + adaptive zoom run once in
// the background. A frame is then warped on the GPU (GyroWarpMap.swift): libsqgyro warps small probe planes into a map
// of where each pixel samples the source (cached per frame time), and a Metal pass resamples the frame with it into a
// new buffer of the same pixel format (bi-planar Y'CbCr 8/10-bit, BGRA). The old CPU-buffer warp (55-90 ms per 4K frame)
// stays as the reference and as the fallback without Metal.

/// libsqgyro's C API (include/sqgyro.h), bound with dlsym (tests build one from fake C functions).
struct SQGyroLibrary: @unchecked Sendable {
    typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> OpaquePointer?
    typealias SetParams = @convention(c) (OpaquePointer, Double, Double, UInt8, Double) -> Void
    typealias SetLensParams = @convention(c) (OpaquePointer, Double, Double, Double) -> Void
    typealias Recompute = @convention(c) (OpaquePointer) -> Int32
    typealias ProcessPlane = @convention(c) (OpaquePointer, Int64, UInt32, UInt32, UInt32,
                                             UnsafeMutableRawPointer, Int, UnsafeMutableRawPointer, Int, UInt8) -> Int32
    typealias MotionStep = @convention(c) (OpaquePointer, Int64, Int64, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>) -> Int32
    typealias Free = @convention(c) (OpaquePointer) -> Void
    typealias Fork = @convention(c) (OpaquePointer) -> OpaquePointer?
    typealias SetRotation = @convention(c) (OpaquePointer, Double) -> Void
    typealias CorrectionAngle = @convention(c) (OpaquePointer, Int64, UnsafeMutablePointer<Double>) -> Int32

    let open: Open, setParams: SetParams, recompute: Recompute, processPlane: ProcessPlane, motionStep: MotionStep, free: Free
    /// Field of View / Lens Correction / Sync Offset (v59). nil in a library built before them: those options are ignored.
    let setLensParams: SetLensParams?
    /// Copy of an opened handle without re-reading the file (an option change on an analyzed file). nil in an older library.
    var fork: Fork? = nil
    /// Overrides the file's rotation tag for the horizon lock (the library reads the tag itself on open). Optional.
    var setRotation: SetRotation? = nil
    /// Measuring aid (tests): total smoothing/horizon correction angle at a time, degrees. Optional.
    var correctionAngle: CorrectionAngle? = nil

    /// SQGyroInfo layout (repr(C)): u32 width @0, u32 height @4, f64 fps @8, f64 duration_ms @16, u64 frame_count @24,
    /// f64 readout_ms @32, u8 has_motion @40, u8 accurate @41, char camera[128] @42, char lens[128] @170. 304 bytes.
    static let infoSize = 304

    static func load(_ url: URL) -> SQGyroLibrary? {
        guard let h = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let o = sym("sqgyro_open", Open.self), let s = sym("sqgyro_set_params", SetParams.self),
              let r = sym("sqgyro_recompute", Recompute.self), let p = sym("sqgyro_process_plane", ProcessPlane.self),
              let m = sym("sqgyro_motion_step", MotionStep.self), let f = sym("sqgyro_free", Free.self) else {
            dlclose(h); return nil
        }
        var lib = SQGyroLibrary(open: o, setParams: s, recompute: r, processPlane: p, motionStep: m, free: f,
                                setLensParams: sym("sqgyro_set_lens_params", SetLensParams.self))
        lib.fork = sym("sqgyro_fork", Fork.self)
        lib.setRotation = sym("sqgyro_set_rotation", SetRotation.self)
        lib.correctionAngle = sym("sqgyro_correction_angle", CorrectionAngle.self)
        return lib
    }
}

/// Plane layouts of `sqgyro_process_plane`.
private enum PlaneKind: UInt32 { case luma8 = 0, uv8 = 1, luma16 = 2, uv16 = 3, bgra8 = 4 }

/// How a pixel format is warped: plane kinds and range. nil = not supported (the frame shows unwarped).
private func planeLayout(_ format: OSType) -> (kinds: [PlaneKind], fullRange: Bool)? {
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
        ([.luma8, .uv8], false)
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        ([.luma8, .uv8], true)
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        ([.luma16, .uv16], false)
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        ([.luma16, .uv16], true)
    case kCVPixelFormatType_32BGRA:
        ([.bgra8], true)
    default:
        nil
    }
}

/// One analysis: a gyroflow handle for (file, options). The handle is freed when the last user lets go.
final class GyroAnalysis: @unchecked Sendable {
    let lib: SQGyroLibrary
    let key: GyroflowEngine.Key
    /// Set once by the background job (before `done` is signalled); read-only afterwards.
    private(set) var handle: OpaquePointer?
    let state: Mutex<GyroAnalysisState>
    let done = DispatchSemaphore(value: 0)
    let finished = Atomic<Bool>(false)
    /// Set by `GyroflowEngine.cancel`: the job's result is dropped (libsqgyro's open cannot be interrupted).
    let cancelled = Atomic<Bool>(false)
    /// Set when the background job got its turn (a newer option set of the same file may replace a job that waits).
    let running = Atomic<Bool>(false)
    /// An export asked for it: never replaced by a newer option set.
    let exportOwned = Atomic<Bool>(false)
    /// Last warp (input buffer, time) -> output: a repaint of the same frame reuses it.
    let memo = Mutex<Memo?>(nil)
    struct Memo: @unchecked Sendable { let input: ObjectIdentifier; let ts: Int64; let output: CVPixelBuffer }
    /// The file's frame size (from libsqgyro), set with `handle`.
    private(set) var frameSize = (width: 0, height: 0)
    /// The file's frame rate (for prefetching the next frame's map).
    private(set) var fps = 0.0
    /// GPU warp maps by frame time, least recently used first.
    let maps = Mutex<[(ts: Int64, map: GyroWarpMapGPU)]>([])
    static let mapCapacity = 16
    /// Frame times whose map is being built in the background.
    let pending = Mutex<Set<Int64>>([])

    /// A finished analysis of the same file: its handle is forked instead of reading the file again (kept alive here).
    private var donor: GyroAnalysis?

    init(lib: SQGyroLibrary, key: GyroflowEngine.Key, donor: GyroAnalysis? = nil) {
        self.lib = lib; self.key = key; self.donor = donor; state = Mutex(.analysing(0))
    }

    func run(progress: () -> Void) {
        defer { donor = nil }
        running.store(true, ordering: .releasing)
        guard !cancelled.load(ordering: .acquiring) else { finish(.idle); return }
        var err = [CChar](repeating: 0, count: 512)
        let info = UnsafeMutableRawPointer.allocate(byteCount: SQGyroLibrary.infoSize, alignment: 8)
        defer { info.deallocate() }
        var forked: OpaquePointer?
        if let donor, let dh = donor.handle, let fork = lib.fork {
            forked = fork(dh)
            if forked != nil {
                info.storeBytes(of: UInt32(donor.frameSize.width), toByteOffset: 0, as: UInt32.self)
                info.storeBytes(of: UInt32(donor.frameSize.height), toByteOffset: 4, as: UInt32.self)
                info.storeBytes(of: donor.fps, toByteOffset: 8, as: Double.self)
            }
        }
        let h = forked ?? key.path.withCString { lib.open($0, info, &err, err.count) }
        guard let h else {
            let why = String(cString: err)
            finish(.failed(why.contains("no gyro data") ? GyroStabilization.noGyroDataReason : "Gyroflow could not read this file (\(why))."))
            return
        }
        guard !cancelled.load(ordering: .acquiring) else { lib.free(h); finish(.idle); return }
        frameSize = (Int(info.load(fromByteOffset: 0, as: UInt32.self)), Int(info.load(fromByteOffset: 4, as: UInt32.self)))
        fps = info.load(fromByteOffset: 8, as: Double.self)
        state.withLock { $0 = .analysing(0.6) }
        progress()
        let o = key.options
        lib.setParams(h, o.smoothness, o.zoomLimit, o.rollingShutter ? 1 : 0, o.horizonLock)
        lib.setLensParams?(h, o.fieldOfView / 100, o.lensCorrection / 100, o.syncOffsetMS)
        guard lib.recompute(h) == 1 else {
            lib.free(h)
            finish(.failed("Gyroflow could not smooth this clip's motion."))
            return
        }
        guard !cancelled.load(ordering: .acquiring) else { lib.free(h); finish(.idle); return }
        handle = h
        finish(.ready)
    }

    private func finish(_ s: GyroAnalysisState) {
        state.withLock { $0 = s }
        finished.store(true, ordering: .releasing)
        done.signal()
    }

    /// Waits for the analysis (export). Signals again so every waiter wakes.
    func wait() {
        guard !finished.load(ordering: .acquiring) else { return }
        done.wait(); done.signal()
    }

    deinit { if let handle { lib.free(handle) } }
}

/// gyroflow_core via libsqgyro. Safe from any thread.
public final class GyroflowEngine: GyroStabilizationEngine, @unchecked Sendable {
    public static let missingReason = "The Gyroflow engine is not installed in this build."
    /// The app's engine (library from the app bundle, `SQ_GYRO_LIB`, or the repo's build/gyro).
    public static let shared = GyroflowEngine()

    struct Key: Hashable, Sendable { let path: String; let options: GyroflowOptions }

    private let lib: SQGyroLibrary?
    private struct State {
        var analyses: [Key: GyroAnalysis] = [:]
        /// Canceled by the user: playback's warp does not start these again (Analyze / `prepare` does).
        var held: Set<Key> = []
        /// When an export last asked for the key (`warp(wait: true)`): a cancel that arrives while the export runs must
        /// not be undone by its next frame (`continuesExport`).
        var exportCall: [Key: ContinuousClock.Instant] = [:]
        /// Least recently used first.
        var order: [Key] = []
        /// The newest finished analysis per file: playback shows it while a newer option set is still being smoothed.
        var lastReady: [String: Key] = [:]
        /// One smoothing job at a time per file (a slider drag makes one option set per tick).
        var gates: [String: DispatchSemaphore] = [:]
        var observers: [@Sendable () -> Void] = []
        var pools: [PoolKey: CVPixelBufferPool] = [:]
    }
    private struct PoolKey: Hashable { let format: OSType; let width: Int; let height: Int }
    private let state = Mutex(State())
    /// Analyzes kept (each holds the clip's gyro data and GPU warp state). Older ones are freed when unused.
    private let capacity: Int
    private let queue = DispatchQueue(label: "sq.gyroflow.analysis", qos: .userInitiated, attributes: .concurrent)

    /// `libraryURL` nil = the default search (`libraryCandidates`).
    public init(libraryURL: URL? = nil, capacity: Int = 4) {
        self.capacity = max(1, capacity)
        let urls = libraryURL.map { [$0] } ?? Self.libraryCandidates()
        lib = urls.lazy.compactMap { FileManager.default.fileExists(atPath: $0.path) ? SQGyroLibrary.load($0) : nil }.first
    }

    /// An engine over a given library (tests: fake C functions, no Rust build needed).
    init(library: SQGyroLibrary?, capacity: Int = 4) {
        self.capacity = max(1, capacity)
        lib = library
    }

    /// Where libsqgyro.dylib is looked for: `SQ_GYRO_LIB`, the app's Frameworks folder, the repo's build/gyro (dev runs
    /// and package tests).
    static func libraryCandidates() -> [URL] {
        var urls: [URL] = []
        if let env = ProcessInfo.processInfo.environment["SQ_GYRO_LIB"], !env.isEmpty { urls.append(URL(fileURLWithPath: env)) }
        if let fw = Bundle.main.privateFrameworksURL { urls.append(fw.appendingPathComponent("libsqgyro.dylib")) }
        // Packages/SQAnalysis/Sources/SQAnalysis/GyroflowEngine.swift -> repo root
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        urls.append(repo.appendingPathComponent("build/gyro/libsqgyro.dylib"))
        return urls
    }

    public var availability: GyroEngineAvailability { lib == nil ? .unavailable(Self.missingReason) : .available }

    public func analysisState(path: String, options: GyroflowOptions) -> GyroAnalysisState {
        guard let a = state.withLock({ $0.analyses[Key(path: path, options: options)] }) else { return .idle }
        return a.state.withLock { $0 }
    }

    /// Starts the analysis; a failed one is tried again (Analyze Again), a canceled one is started anew.
    public func prepare(path: String, options: GyroflowOptions) {
        let key = Key(path: path, options: options)
        state.withLock { s in
            s.held.remove(key)
            if let a = s.analyses[key], case .failed = a.state.withLock({ $0 }) { s.analyses[key] = nil }
        }
        _ = analysis(key)
    }

    /// Stops the analysis of this file and options: its state is `.idle` at once, a result that still arrives is
    /// dropped, and playback does not start it again until `prepare`. A finished analysis is left alone.
    public func cancel(path: String, options: GyroflowOptions) {
        let key = Key(path: path, options: options)
        let dropped = state.withLock { s -> GyroAnalysis? in
            guard let a = s.analyses[key], !a.finished.load(ordering: .acquiring) else { return nil }
            s.analyses[key] = nil
            s.order.removeAll { $0 == key }
            s.held.insert(key)
            return a
        }
        guard let dropped else { return }
        dropped.cancelled.store(true, ordering: .releasing)
        let observers = state.withLock { $0.observers }
        queue.async { for f in observers { f() } }
    }

    public func addObserver(_ f: @escaping @Sendable () -> Void) { state.withLock { $0.observers.append(f) } }

    public func runningAnalyses() -> [GyroRunningAnalysis] {
        let all = state.withLock { s in s.order.compactMap { k in s.analyses[k].map { (k, $0) } } }
        return all.compactMap { k, a in
            guard case .analysing(let p) = a.state.withLock({ $0 }) else { return nil }
            return GyroRunningAnalysis(path: k.path, options: k.options, progress: p)
        }
    }

    /// The analysis for `key`, started when new (evicting the least recently used beyond `capacity`). `start` false:
    /// a key the user canceled is not started again (nil).
    private func analysis(_ key: Key, start: Bool = true, export: Bool = false, replacing: Bool = false) -> GyroAnalysis? {
        guard let lib else { return nil }
        let found = state.withLock { s -> (GyroAnalysis, Bool)? in
            let now = ContinuousClock.now
            if export {
                // The export keeps asking while the user cancels: the next frame must not start the analysis again.
                let last = s.exportCall[key]
                s.exportCall[key] = now
                if Self.continuesExport(held: s.held.contains(key), lastExportCall: last, now: now) { return nil }
            }
            if !start, s.held.contains(key) { return nil }
            s.held.remove(key)
            s.order.removeAll { $0 == key }
            s.order.append(key)
            if let a = s.analyses[key] {
                if export { a.exportOwned.store(true, ordering: .releasing) }
                return (a, false)
            }
            // Playback asks for the current options: after a drag tick the jobs of this file that still wait for their turn are obsolete
            // (Analyze / prepare and export never replace one).
            for (k, old) in s.analyses where replacing && k.path == key.path && !old.finished.load(ordering: .acquiring)
                && !old.running.load(ordering: .acquiring) && !old.exportOwned.load(ordering: .acquiring) {
                old.cancelled.store(true, ordering: .releasing)
                s.analyses[k] = nil
                s.order.removeAll { $0 == k }
            }
            let donor = s.analyses.values.first { $0.key.path == key.path && $0.handle != nil && $0.finished.load(ordering: .acquiring) }
            let a = GyroAnalysis(lib: lib, key: key, donor: donor)
            if export { a.exportOwned.store(true, ordering: .releasing) }
            s.analyses[key] = a
            // The file's newest finished analysis stays: playback shows it while the new options are smoothed.
            let keep = s.lastReady[key.path]
            while s.order.count > capacity, let i = s.order.firstIndex(where: { $0 != keep }) {
                s.analyses[s.order.remove(at: i)] = nil
            }
            return (a, true)
        }
        guard let (a, isNew) = found else { return nil }
        if isNew {
            let gate = state.withLock { s -> DispatchSemaphore in
                if let g = s.gates[key.path] { return g }
                let g = DispatchSemaphore(value: 1)
                s.gates[key.path] = g
                return g
            }
            // Observers hear the start, the end of reading the file, and the end (Analyze row progress, redraw).
            let notify: @Sendable () -> Void = { [weak self] in
                for f in self?.state.withLock({ $0.observers }) ?? [] { f() }
            }
            queue.async { [self] in      // never call observers from the caller's thread (the render loop may hold its locks)
                notify()
                gate.wait()
                a.run(progress: notify)
                gate.signal()
                if case .ready = a.state.withLock({ $0 }) {
                    self.state.withLock { $0.lastReady[key.path] = key }
                }
                notify()
            }
        }
        return a
    }

    /// A canceled analysis that an export asked for within this long is the same export going on: it is not restarted.
    static let exportContinuation: Duration = .seconds(2)

    /// Whether an export frame (`warp(wait: true)`) belongs to an export that was already running when the user
    /// canceled the analysis. A cancel before the export started (nothing asked within `exportContinuation`) is
    /// overridden by the export, which needs the analysis.
    /// shortcut: judged by the gap between frame requests (no export start/end hook), so a stalled export of more than
    /// 2 s restarts a canceled analysis; upgrade when the export gets a run id.
    static func continuesExport(held: Bool, lastExportCall: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard held, let last = lastExportCall else { return false }
        return now - last < exportContinuation
    }

    public func warp(_ frame: CVPixelBuffer, path: String, options: GyroflowOptions, timestampUS: Int64, wait: Bool) -> CVPixelBuffer? {
        // Export (`wait`) needs the analysis, also one canceled before it began; playback leaves a canceled one alone.
        guard var a = analysis(Key(path: path, options: options), start: wait, export: wait, replacing: !wait) else { return nil }
        if wait { a.wait() } else if !a.finished.load(ordering: .acquiring), let stale = staleAnalysis(path: path) {
            a = stale     // playback: the last finished smoothing of this file until the new options are ready
        }
        guard a.finished.load(ordering: .acquiring), let h = a.handle else { return nil }
        let id = ObjectIdentifier(frame)
        if let m = a.memo.withLock({ $0 }), m.input == id, m.ts == timestampUS { return m.output }
        let out: CVPixelBuffer?
        if let gpu, GyroMetalWarp.supports(CVPixelBufferGetPixelFormatType(frame)) {
            out = warpOnGPU(frame, a, h, gpu, timestampUS: timestampUS)
            // Playback walks forward: build the next frame's map while this one is shown.
            if !wait { prefetchMap(a, h, gpu, timestampUS: timestampUS) }
        } else {
            out = warpOnCPU(frame, a, h, timestampUS: timestampUS)
        }
        guard let out else { return nil }
        CVBufferPropagateAttachments(frame, out)
        let memo = GyroAnalysis.Memo(input: id, ts: timestampUS, output: out)
        a.memo.withLock { $0 = memo }
        return out
    }

    private func staleAnalysis(path: String) -> GyroAnalysis? {
        state.withLock { s in
            guard let k = s.lastReady[path], let a = s.analyses[k], a.finished.load(ordering: .acquiring), a.handle != nil else { return nil }
            return a
        }
    }

    /// Fixed map divisor (measurements); nil = `GyroWarpMap.divisor`.
    var mapDivisor: Int?

    /// The Metal pass (nil = no GPU: every warp goes through libsqgyro's CPU buffers).
    private let gpu = GyroMetalWarp.shared

    private func warpOnGPU(_ frame: CVPixelBuffer, _ a: GyroAnalysis, _ h: OpaquePointer, _ gpu: GyroMetalWarp, timestampUS: Int64) -> CVPixelBuffer? {
        guard let map = map(a, h, gpu, timestampUS: timestampUS),
              let out = outputBuffer(format: CVPixelBufferGetPixelFormatType(frame), width: CVPixelBufferGetWidth(frame),
                                     height: CVPixelBufferGetHeight(frame)),
              gpu.warp(frame, into: out, map: map, fullRange: planeLayout(CVPixelBufferGetPixelFormatType(frame))?.fullRange ?? false)
        else { return nil }
        return out
    }

    /// The map for a frame time: cached, else built now (two probe warps at a quarter size, ~1-3 ms).
    private func map(_ a: GyroAnalysis, _ h: OpaquePointer, _ gpu: GyroMetalWarp, timestampUS: Int64) -> GyroWarpMapGPU? {
        if let m = cachedMap(a, timestampUS) { return m }
        guard let m = buildMap(a, h, gpu, timestampUS: timestampUS) else { return nil }
        storeMap(a, timestampUS, m)
        return m
    }

    private func cachedMap(_ a: GyroAnalysis, _ ts: Int64) -> GyroWarpMapGPU? {
        a.maps.withLock { maps in
            guard let i = maps.firstIndex(where: { $0.ts == ts }) else { return nil }
            let e = maps.remove(at: i)
            maps.append(e)
            return e.map
        }
    }

    private func storeMap(_ a: GyroAnalysis, _ ts: Int64, _ m: GyroWarpMapGPU) {
        a.maps.withLock { maps in
            maps.removeAll { $0.ts == ts }
            maps.append((ts, m))
            if maps.count > GyroAnalysis.mapCapacity { maps.removeFirst(maps.count - GyroAnalysis.mapCapacity) }
        }
    }

    /// Warps the probe planes for `timestampUS` through libsqgyro and uploads the decoded map.
    private func buildMap(_ a: GyroAnalysis, _ h: OpaquePointer, _ gpu: GyroMetalWarp, timestampUS: Int64) -> GyroWarpMapGPU? {
        let (mw, mh) = GyroWarpMap.size(frameWidth: max(a.frameSize.width, 1), frameHeight: max(a.frameSize.height, 1),
                                        divisor: mapDivisor ?? GyroWarpMap.divisor(frameWidth: a.frameSize.width, frameHeight: a.frameSize.height))
        let probes = GyroProbes.shared(width: mw, height: mh)
        return gpu.makeMap(width: mw, height: mh) { xy, coverage in
            // Full range: the 1-channel probe's background is 0, so a filter reaching outside the picture shows.
            a.lib.processPlane(h, timestampUS, PlaneKind.uv16.rawValue, UInt32(mw), UInt32(mh),
                               UnsafeMutableRawPointer(probes.xy.baseAddress!), mw * 4, xy, mw * 4, 1) == 1
                && a.lib.processPlane(h, timestampUS, PlaneKind.luma16.rawValue, UInt32(mw), UInt32(mh),
                                      UnsafeMutableRawPointer(probes.coverage.baseAddress!), mw * 2, coverage, mw * 2, 1) == 1
        }
    }

    private let prefetchQueue = DispatchQueue(label: "sq.gyroflow.prefetch", qos: .userInitiated)

    /// Builds the map of the frame after `timestampUS` in the background (playback asks for it next).
    private func prefetchMap(_ a: GyroAnalysis, _ h: OpaquePointer, _ gpu: GyroMetalWarp, timestampUS: Int64) {
        guard a.fps > 0 else { return }
        // Frame times come from rational pts rounded to µs; predict the next one the same way.
        let frame = (Double(timestampUS) * a.fps / 1_000_000).rounded()
        let next = Int64(((frame + 1) / a.fps * 1_000_000).rounded())
        guard next > timestampUS, cachedMap(a, next) == nil,
              a.pending.withLock({ $0.insert(next).inserted }) else { return }
        prefetchQueue.async { [weak self] in
            defer { _ = a.pending.withLock { $0.remove(next) } }
            guard let self, let m = self.buildMap(a, h, gpu, timestampUS: next) else { return }
            self.storeMap(a, next, m)
        }
    }

    /// The CPU-buffer warp through libsqgyro (each plane uploaded, warped and read back by wgpu): the reference the GPU
    /// path is tested against, and the path without Metal.
    func warpOnCPU(_ frame: CVPixelBuffer, path: String, options: GyroflowOptions, timestampUS: Int64) -> CVPixelBuffer? {
        guard let a = analysis(Key(path: path, options: options)) else { return nil }
        a.wait()
        guard let h = a.handle else { return nil }
        return warpOnCPU(frame, a, h, timestampUS: timestampUS)
    }

    /// Time to warp one frame on the GPU split into map (built fresh) and Metal pass, for measurements.
    func gpuTiming(_ frame: CVPixelBuffer, path: String, options: GyroflowOptions, timestampUS: Int64) -> (map: Duration, pass: Duration)? {
        guard let gpu, let a = analysis(Key(path: path, options: options)) else { return nil }
        a.wait()
        guard let h = a.handle, let out = outputBuffer(format: CVPixelBufferGetPixelFormatType(frame),
                                                       width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        else { return nil }
        let t0 = ContinuousClock.now
        guard let m = buildMap(a, h, gpu, timestampUS: timestampUS) else { return nil }
        let t1 = ContinuousClock.now
        guard gpu.warp(frame, into: out, map: m, fullRange: planeLayout(CVPixelBufferGetPixelFormatType(frame))?.fullRange ?? false)
        else { return nil }
        return (t1 - t0, ContinuousClock.now - t1)
    }

    private func warpOnCPU(_ frame: CVPixelBuffer, _ a: GyroAnalysis, _ h: OpaquePointer, timestampUS: Int64) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(frame)
        guard let layout = planeLayout(format) else { return nil }
        let w = CVPixelBufferGetWidth(frame), ht = CVPixelBufferGetHeight(frame)
        guard let out = outputBuffer(format: format, width: w, height: ht) else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        let planar = CVPixelBufferIsPlanar(frame)
        for (i, kind) in layout.kinds.enumerated() {
            let src = planar ? CVPixelBufferGetBaseAddressOfPlane(frame, i) : CVPixelBufferGetBaseAddress(frame)
            let dst = planar ? CVPixelBufferGetBaseAddressOfPlane(out, i) : CVPixelBufferGetBaseAddress(out)
            guard let src, let dst else { return nil }
            let pw = planar ? CVPixelBufferGetWidthOfPlane(frame, i) : w
            let ph = planar ? CVPixelBufferGetHeightOfPlane(frame, i) : ht
            let sbpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(frame, i) : CVPixelBufferGetBytesPerRow(frame)
            let dbpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(out, i) : CVPixelBufferGetBytesPerRow(out)
            guard a.lib.processPlane(h, timestampUS, kind.rawValue, UInt32(pw), UInt32(ph), src, sbpr, dst, dbpr,
                                     layout.fullRange ? 1 : 0) == 1 else { return nil }
        }
        CVBufferPropagateAttachments(frame, out)
        return out
    }

    /// Camera rotation per frame step, raw and stabilized (degrees), for measurements. nil = not analyzed.
    public func motionStep(path: String, options: GyroflowOptions, timestampUS: Int64, stepUS: Int64) -> (raw: Double, stabilised: Double)? {
        guard let a = state.withLock({ $0.analyses[Key(path: path, options: options)] }), a.finished.load(ordering: .acquiring),
              let h = a.handle else { return nil }
        var r = 0.0, s = 0.0
        guard a.lib.motionStep(h, timestampUS, stepUS, &r, &s) == 1 else { return nil }
        return (r, s)
    }

    private func outputBuffer(format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
        let key = PoolKey(format: format, width: width, height: height)
        let pool: CVPixelBufferPool? = state.withLock { s in
            if let p = s.pools[key] { return p }
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 2] as CFDictionary, attrs as CFDictionary, &p)
            if s.pools.count > 8 { s.pools.removeAll() }
            s.pools[key] = p
            return p
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}
