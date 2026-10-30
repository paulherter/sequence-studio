import Foundation
import Synchronization

/// RAM and cores of this Mac, or of a smaller one simulated with `SQ_RAM_GB` / `SQ_CORES` (both only ever lower the real
/// values), so tests and benches can play a MacBook Air 8 GB on any machine.
public struct MachineResources: Sendable, Hashable {
    public static let gib: UInt64 = 1 << 30
    public var memoryBytes: UInt64
    public var cores: Int
    /// Intel Mac (software decode and the media engine are far slower there).
    public var isIntel: Bool

    public init(memoryBytes: UInt64, cores: Int, isIntel: Bool = false) {
        self.memoryBytes = memoryBytes; self.cores = max(1, cores); self.isIntel = isIntel
    }

    #if arch(x86_64)
    public static let buildIsIntel = true
    #else
    public static let buildIsIntel = false
    #endif

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                               cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                               isIntel: Bool = MachineResources.buildIsIntel) -> MachineResources {
        var m = MachineResources(memoryBytes: physicalMemory, cores: cores, isIntel: isIntel)
        if let v = environment["SQ_RAM_GB"].flatMap(Double.init), v.isFinite, v > 0 {
            m.memoryBytes = min(physicalMemory, UInt64(v * Double(gib)))
        }
        if let c = environment["SQ_CORES"].flatMap(Int.init), c > 0 { m.cores = min(m.cores, c) }
        return m
    }

    /// 8 GB or less (MacBook Air base models): the same line as `MemoryBudget.isLowMemory`.
    public var isLowMemory: Bool { memoryBytes <= 8 * Self.gib }

    /// Intel, 8 GB or less, or 4 cores or fewer: software decode (and its frames) is capped on these.
    public var isWeakForDecode: Bool { isIntel || isLowMemory || cores <= 4 }

    public var limits: WorkLimits { WorkLimits(self) }
}

/// How many background media jobs of each kind run at once. Before (2026-10-04) an import of N files started N probes
/// and N poster decodes at once (each poster an AVAssetImageGenerator with its own 4K decoder session); on an 8 GB Mac
/// that is the swap storm, not the speed-up. Every lane is bounded by cores and narrower on low-memory Macs.
public struct WorkLimits: Sendable, Hashable {
    /// Import: probe (+ copy into Files) of dropped files.
    public var importProbes: Int
    /// Poster / thumbnail frame decodes (one decoder session each).
    public var posterDecodes: Int
    /// Whole-file audio reads (waveform peaks, `BlockingLane.media`).
    public var waveformReads: Int
    /// Background proxy transcodes (ProRes encode + long-GOP decode on the media engine).
    public var proxyTranscodes: Int
    /// Export render: media of one output frame decoded at once (stacked layers). Frames of one output frame are held
    /// anyway, so the width costs no memory; it bounds media-engine and decode-queue contention. 1 = serial.
    public var layerDecodes: Int
    /// Mask tracking: long side of the analyzed frames (px). Optical flow costs grow with the area.
    public var maskTrackDimension: Int
    /// Subject (Magic) mask: long side of the segmented frames and of the stored mattes (px). Vision's segmentation
    /// costs the same at every size (its model input is fixed); the size sets how fine the matte's edge is, what a
    /// decoded frame holds while a backward chunk is walked and what a stored matte weighs.
    public var subjectMaskDimension: Int
    /// Mask tracking backward: seconds of frames read and held at once before they are walked in reverse.
    public var maskTrackChunkSeconds: Double
    /// Export render: submit frame N+1 to the GPU while frame N finishes and encodes. Holds a second frame's compositor
    /// intermediates (~400 MB at 4K), so off on 8 GB Macs (and pointless on one core).
    public var exportRenderAhead: Bool
    /// Export: open VideoToolbox sessions over the whole export (all parallel segments; `DecoderBudget.maxDecoders`).
    public var exportDecoderSessions: Int
    /// Export: bytes of decoded frames kept, look-ahead included (`DecoderBudget.maxBytes`; a 4K 10-bit frame ~25 MB).
    public var exportFrameBytes: Int
    /// Export: free intermediate textures kept by each export compositor (one per parallel segment). The Compositor's
    /// default is 1 GB; on 8 GB Macs 256 MB, the same as the playback pool there (`MemoryBudget.intermediatePoolBytes`).
    public var exportIntermediatePoolBytes: Int
    /// Picture analyzes (Stabilizer: sequential decode + Vision registration, ~0.7 cores and 30-60 MB each), on their
    /// own threads (`BlockingLane.analysis`), not the cooperative pool.
    public var pictureAnalyses: Int

    /// Preview: live software (non-hardware) decoder sessions at most; the idle ones are evicted first. A stack of
    /// layers of software-only media (4:2:2, ProRes RAW...) otherwise holds a session and its reference frames each.
    public var softwareDecoderSessions: Int
    /// Preview: bytes of decoded frames the preview `DecoderBudget` keeps (`DecoderBudget.preview`).
    public var previewDecoderFrameBytes: Int
    /// Preview: decode jobs of the playback `DecodeScheduler` running at once.
    public var previewDecodeJobs: Int
    /// CPU pool (`WorkPools.cpu`): software-path jobs at once (software decode fallback, analysis on the CPU).
    public var cpuFallbackJobs: Int
    /// Preview: decode at half resolution at least (a stack of layers is viewed small anyway).
    public var reducedPreviewDecode: Bool

    /// Memory audit (2026-10-04): in-memory caches, halved on 8 GB Macs, unchanged from 16 GB up. All of them also
    /// shrink under memory pressure (`MemoryPressureRegistry`, `MemoryPressure.budget`).
    /// Project bin posters (`ProjectThumbnails`).
    public var posterCacheBytes: Int
    /// Color page clip frames (`ProjectThumbnails`).
    public var clipFrameCacheBytes: Int
    /// Decoded thumbnails of the bin's `Thumbnailer` (posters and hover scrub frames before they become images).
    public var thumbnailMemoryBytes: Int
    /// Resampled waveform peaks per zoom bucket (`WaveformCache`).
    public var waveformCacheBytes: Int
    /// Frame cache of both monitors together when the setting is Auto (`MemoryBudget.autoFrameCacheBytes`): 8 GB Macs
    /// and smaller 1/6 of RAM, larger 1/4, at most 8 GB.
    public var frameCacheBytes: Int
    /// Free intermediate textures the playback compositor keeps (`MemoryBudget.intermediatePoolBytes`): RAM / 32,
    /// between 128 MB and 1 GB.
    public var intermediatePoolBytes: Int

    public init(_ m: MachineResources) {
        let half = max(1, m.cores / 2)
        let gib = MachineResources.gib
        let low = m.isLowMemory
        posterCacheBytes = low ? 32 << 20 : 64 << 20
        clipFrameCacheBytes = low ? 24 << 20 : 48 << 20
        thumbnailMemoryBytes = low ? 24 << 20 : 48 << 20
        waveformCacheBytes = low ? 32 << 20 : 64 << 20
        frameCacheBytes = low ? Int(m.memoryBytes / 6) : Int(min(m.memoryBytes / 4, 8 * gib))
        intermediatePoolBytes = Int(min(max(m.memoryBytes / 32, 128 << 20), 1 << 30))
        // Weak-Mac part 3 (bench, `SQ_RAM_GB=8`): an export's own footprint was 1.4-1.7 GB with 2 segments, most of it
        // decoded frames kept under the 768 MB budget; halved on 8 GB Macs, unchanged from 16 GB up.
        exportDecoderSessions = m.isLowMemory ? 4 : 8
        exportFrameBytes = m.isLowMemory ? 384 << 20 : 768 << 20
        let weak = m.isWeakForDecode
        softwareDecoderSessions = m.memoryBytes <= 4 * MachineResources.gib || m.cores <= 2 ? 1 : weak ? 2 : 8
        previewDecoderFrameBytes = m.memoryBytes <= 4 * MachineResources.gib || m.cores <= 2 ? 96 << 20 : weak ? 192 << 20 : 768 << 20
        previewDecodeJobs = softwareDecoderSessions == 1 ? 1 : weak ? 2 : 4
        reducedPreviewDecode = weak
        cpuFallbackJobs = weak ? 1 : half
        exportIntermediatePoolBytes = m.isLowMemory ? 256 << 20 : 1 << 30
        if m.isLowMemory {
            importProbes = min(4, half)
            posterDecodes = min(2, half)
            waveformReads = min(2, half)
            proxyTranscodes = 1
            layerDecodes = min(2, half)
            maskTrackDimension = 480
            subjectMaskDimension = 540
            maskTrackChunkSeconds = 0.5
            exportRenderAhead = false
            pictureAnalyses = 1
        } else {
            importProbes = min(8, half)
            posterDecodes = min(6, max(2, half - 1))
            waveformReads = m.cores >= 16 ? 3 : 2
            proxyTranscodes = m.memoryBytes >= 64 * MachineResources.gib && m.cores >= 16 ? 2 : 1
            layerDecodes = min(4, half)
            maskTrackDimension = 640
            subjectMaskDimension = weak ? 640 : 960
            maskTrackChunkSeconds = 1
            exportRenderAhead = m.cores > 1
            pictureAnalyses = m.cores > 4 ? 2 : 1
        }
    }

    /// This Mac's limits (`SQ_RAM_GB` / `SQ_CORES` simulate a smaller one).
    public static let current = MachineResources.current().limits

    /// Seconds one frame's object segmentation (file read + Vision, the Mask tool's subject mode) may take before its
    /// request is given up: the tool says so and the next hover or click starts a new one. A parked frame takes well
    /// under a second; a request that never returns must not leave the tool waiting for the rest of the app run.
    public static let subjectFrameDeadline: Double = 8

    /// Seconds a frame read on the frame lane (mask tracking, matte precompute, people search) may go without a sign of
    /// life (one frame decoded, one frame segmented) before it counts as hung and gives its lane slot back
    /// (`BlockingLane.run(stallAfter:)`). A frame takes well under a second; a seek into a long-GOP 8K file a few.
    public static let frameWorkStallSeconds: Double = 30
}

/// At most `width` async jobs at once; the rest wait suspended (no thread blocked). For async work that is heavy in
/// memory or on the media engine (poster decodes, import probes); blocking read loops go on a `BlockingLane` instead.
public final class AsyncLimiter: Sendable {
    private struct State: ~Copyable {
        var free: Int
        var next = 0
        var waiters: [(id: Int, c: CheckedContinuation<Bool, Never>)] = []
    }
    private let state: Mutex<State>
    public let width: Int

    public init(width: Int) {
        self.width = max(1, width)
        state = Mutex(State(free: max(1, width)))
    }

    public var freeSlots: Int { state.withLock { $0.free } }
    public var waiting: Int { state.withLock { $0.waiters.count } }

    /// Runs `body` once a slot is free (waits through cancellation; `body` sees it).
    public func run<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        _ = await acquire(cancellable: false)
        defer { release() }
        return try await body()
    }

    /// Like `run`, but a task canceled while waiting throws `CancellationError` without running.
    public func runThrowing<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        guard await acquire(cancellable: true) else { throw CancellationError() }
        defer { release() }
        return try await body()
    }

    /// true = got a slot; false = canceled while waiting.
    private func acquire(cancellable: Bool) async -> Bool {
        let id = state.withLock { s -> Int in s.next += 1; return s.next }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let now = state.withLock { s -> Bool? in
                    if s.free > 0 { s.free -= 1; return true }
                    if cancellable && Task.isCancelled { return false }
                    s.waiters.append((id, c))
                    return nil
                }
                if let now { c.resume(returning: now) }
            }
        } onCancel: {
            guard cancellable else { return }
            let c = state.withLock { s -> CheckedContinuation<Bool, Never>? in
                guard let i = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: i).c
            }
            c?.resume(returning: false)
        }
    }

    private func release() {
        let next = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            if s.waiters.isEmpty { s.free += 1; return nil }
            return s.waiters.removeFirst().c
        }
        next?.resume(returning: true)
    }
}
