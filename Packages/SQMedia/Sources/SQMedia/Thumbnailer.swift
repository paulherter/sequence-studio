import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SQCore
import Synchronization

/// Key of one cached thumbnail. Time is quantized to microseconds so equal rational times compare equal.
public struct ThumbnailKey: Hashable, Sendable {
    public var media: UUID
    public var micros: Int64
    /// Pixel height; 0 means native size.
    public var height: Int
    /// F7.3: the pixel aspect the picture is shown with when it is not the file's own; nil = as the file says.
    public var pixelAspect: PixelAspect?
    public init(media: UUID, time: CMTime, height: Int, pixelAspect: PixelAspect? = nil) {
        self.media = media
        self.height = max(0, height)
        self.pixelAspect = pixelAspect
        let t = CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero)
        self.micros = t.isValid && t.isNumeric ? t.value : 0
    }
    var fileName: String {
        "\(media.uuidString)_\(micros)_\(height)\(pixelAspect.map { "_par\($0.num)x\($0.den)" } ?? "").png"
    }
}

/// Which decode slots a request waits for. Interactive requests (hover scrub) never queue behind import posters.
public enum ThumbnailLane: Sendable { case background, interactive }

public enum ThumbnailError: Error, Sendable, LocalizedError {
    case noVideoTrack, generationFailed(String)

    /// English text (the display sink translates it with `SQL10n.localized`).
    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .generationFailed(let why): "The thumbnail could not be made: \(why)"
        }
    }
}

/// Byte-capped LRU of decoded thumbnails. Pure value logic, tested on its own.
struct ThumbnailLRU {
    private(set) var bytes = 0
    let capacity: Int
    /// Memory pressure in force (`MemoryPressure.budget` of `capacity`).
    private(set) var pressure: MemoryPressure = .normal
    var effectiveCapacity: Int { pressure.budget(capacity) }
    private var entries: [ThumbnailKey: (image: CGImage, cost: Int, stamp: UInt64)] = [:]
    private var clock: UInt64 = 0
    init(capacity: Int) { self.capacity = capacity }
    var count: Int { entries.count }

    mutating func get(_ k: ThumbnailKey) -> CGImage? {
        guard var e = entries[k] else { return nil }
        clock += 1; e.stamp = clock; entries[k] = e
        return e.image
    }
    mutating func put(_ k: ThumbnailKey, _ image: CGImage) {
        let cost = max(1, image.bytesPerRow * image.height)
        if let old = entries.removeValue(forKey: k) { bytes -= old.cost }
        guard cost <= effectiveCapacity else { return }
        clock += 1
        entries[k] = (image, cost, clock); bytes += cost
        trim()
    }
    /// Memory pressure: caps the LRU at its share of the capacity and drops the oldest beyond it; normal lifts the cap.
    mutating func apply(_ level: MemoryPressure) {
        pressure = level
        trim()
    }
    private mutating func trim() {
        while bytes > effectiveCapacity, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }) {
            bytes -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
        }
    }
    mutating func removeMedia(_ id: UUID) {
        for k in Array(entries.keys) where k.media == id { bytes -= entries[k]!.cost; entries.removeValue(forKey: k) }
    }
}

/// First-frame / at-time thumbnails for clip drawing (tracks >= 32 pt). Async, cancellable; concurrent requests for the
/// same key share one generation. Memory LRU with a byte cap plus an optional PNG disk cache.
public actor Thumbnailer {
    private var lru: ThumbnailLRU
    private let diskDirectory: URL?
    /// One generation per key; `waiters` are the requesters' tokens (a token leaves once, however it leaves). `batch`: the
    /// key is one time of a batch (`thumbnails(at:)`).
    private struct Flight { var task: Task<CGImage, Error>; var waiters: Set<Int>; var batch: Int? }
    private var inflight: [ThumbnailKey: Flight] = [:]
    /// Batches still running: their generator task's cancel and how many of their keys are still wanted. A batch is
    /// canceled only when every key has lost its last requester.
    private var batches: [Int: (cancel: @Sendable () -> Void, live: Int)] = [:]
    private var nextToken = 0, nextBatch = 0
    /// Number of AVAssetImageGenerator runs so far (for tests and diagnostics). Counted when a decode slot is taken, so a
    /// request canceled while waiting for one does not count.
    public private(set) var generationCount = 0

    /// Weak-Mac part 2: frame decodes running at once (each an AVAssetImageGenerator with its own decoder session; an
    /// import of 80 4K files used to start 80). Shared by every Thumbnailer: `WorkLimits.posterDecodes`.
    public static let decodes = AsyncLimiter(width: WorkLimits.current.posterDecodes)
    /// One slot of its own for `.interactive` requests (hover scrub, newest request only), so they never wait behind posters.
    public static let interactiveDecodes = AsyncLimiter(width: 1)
    private let limiter: AsyncLimiter
    private let interactiveLimiter: AsyncLimiter

    /// Registration with the memory-pressure registry (the LRU shrinks to `MemoryPressure.budget`).
    private let pressureToken: Mutex<MemoryPressureToken?> = Mutex(nil)
    private let pressure: MemoryPressureRegistry?

    public init(memoryBytes: Int = 64 * 1024 * 1024, diskDirectory: URL? = nil, limiter: AsyncLimiter = Thumbnailer.decodes,
                interactiveLimiter: AsyncLimiter = Thumbnailer.interactiveDecodes,
                pressure: MemoryPressureRegistry? = .shared) {
        self.limiter = limiter
        self.interactiveLimiter = interactiveLimiter
        lru = ThumbnailLRU(capacity: memoryBytes)
        self.diskDirectory = diskDirectory
        self.pressure = pressure
        if let d = diskDirectory { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        if let pressure {
            let token = pressure.register("thumbnails") { [weak self] level in
                Task { await self?.memoryPressureDelivered(level) }
            }
            pressureToken.withLock { $0 = token }
        }
    }

    public var cachedBytes: Int { lru.bytes }
    /// The memory cap in force (the full `memoryBytes`, or its share under memory pressure).
    public var memoryCap: Int { lru.effectiveCapacity }

    public func applyMemoryPressure(_ level: MemoryPressure) { lru.apply(level) }

    /// A registry level hopping onto the actor. Each hop is its own task, so hops may arrive out of order: the registry's
    /// current level is applied, not the delivered one (a warning arriving after a later normal is stale).
    func memoryPressureDelivered(_ level: MemoryPressure) { lru.apply(pressure?.level ?? level) }

    /// Thumbnail of `url` at `time`, scaled to `height` pixels (0 = native), preferred transform applied.
    /// `exact` decodes the precise frame; otherwise the nearest sync sample is acceptable (faster).
    /// `pixelAspect` (F7.3): the pixel aspect the media item is shown with (`VideoTrackInfo.displayPixelAspect`), so the
    /// thumbnail has the shape playback and export draw; nil = the file's own tag (what the system decoder applies).
    public func thumbnail(media: UUID, url: URL, at time: CMTime = .zero, height: Int,
                          exact: Bool = true, lane: ThumbnailLane = .background,
                          pixelAspect: PixelAspect? = nil) async throws -> CGImage {
        let key = ThumbnailKey(media: media, time: time, height: height, pixelAspect: pixelAspect)
        if let hit = cached(key) { return hit }
        if inflight[key] == nil {
            inflight[key] = Flight(task: singleTask(url: url, time: time, height: key.height, exact: exact, lane: lane,
                                                    pixelAspect: pixelAspect), waiters: [], batch: nil)
        }
        return try await collect([join(key)])[0].get()
    }

    /// Several times of one file, scaled to `height`: what `thumbnail` gives for each, under the same cache keys, but the
    /// times not cached or already being made go through ONE generator call (`images(for:)`, cheaper per frame than a
    /// generator per frame; docs/PLAYBACK-PERF.md "Import: posters, per variant") in one slot of the lane's limiter.
    /// Each time has its own result: a time the file cannot give fails alone. A single request for one of the times joins
    /// the batch; the batch is canceled only when every time has lost its last requester. Stills, WebM and MXF keep their
    /// own still paths (one decode per time).
    public func thumbnails(media: UUID, url: URL, at times: [CMTime], height: Int, exact: Bool = true,
                           lane: ThumbnailLane = .background, pixelAspect: PixelAspect? = nil) async -> [Result<CGImage, any Error>] {
        let keys = times.map { ThumbnailKey(media: media, time: $0, height: height, pixelAspect: pixelAspect) }
        var out = [Result<CGImage, any Error>?](repeating: nil, count: times.count)
        var fresh: [(key: ThumbnailKey, time: CMTime)] = []
        for (i, key) in keys.enumerated() {
            if let hit = cached(key) { out[i] = .success(hit) }
            else if inflight[key] == nil, !fresh.contains(where: { $0.key == key }) { fresh.append((key, times[i])) }
        }
        let h = max(0, height)
        if fresh.count > 1, !StillImage.isStill(url), !WebMFile.isWebM(url), !MXFFile.isMXF(url) {
            let limiter = lane == .interactive ? interactiveLimiter : self.limiter
            let at = fresh.map(\.time)
            let batch = Task.detached {
                try await limiter.runThrowing {
                    await self.decodeStarted()
                    return try await Self.generateBatch(url: url, times: at, height: h, exact: exact, shape: pixelAspect != nil)
                }
            }
            let id = nextBatch; nextBatch += 1
            batches[id] = ({ batch.cancel() }, fresh.count)
            for (j, f) in fresh.enumerated() {
                let task = Task.detached {
                    let made = try await batch.value
                    try Task.checkCancellation()
                    return await Self.shaped(try made.images[j].get(), url: url, known: made.shape, to: pixelAspect)
                }
                inflight[f.key] = Flight(task: task, waiters: [], batch: id)
            }
        } else {
            for f in fresh {
                inflight[f.key] = Flight(task: singleTask(url: url, time: f.time, height: h, exact: exact, lane: lane,
                                                          pixelAspect: pixelAspect), waiters: [], batch: nil)
            }
        }
        let open = keys.indices.filter { out[$0] == nil }
        let got = await collect(open.map { join(keys[$0]) })
        for (n, i) in open.enumerated() { out[i] = got[n] }
        return out.map { $0! }
    }

    /// First frame convenience.
    public func firstFrame(media: UUID, url: URL, height: Int) async throws -> CGImage {
        try await thumbnail(media: media, url: url, at: .zero, height: height)
    }

    /// Drops cached thumbnails of one media (e.g. after relink). Disk files of that media are removed too.
    public func invalidate(media: UUID) {
        lru.removeMedia(media)
        if let d = diskDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) {
            for n in names where n.hasPrefix(media.uuidString) { try? FileManager.default.removeItem(at: d.appendingPathComponent(n)) }
        }
    }

    // MARK: internals

    private func decodeStarted() { generationCount += 1 }

    /// The memory or disk cache's picture for `key`.
    private func cached(_ key: ThumbnailKey) -> CGImage? {
        if let hit = lru.get(key) { return hit }
        if let disk = loadFromDisk(key) { lru.put(key, disk); return disk }
        return nil
    }

    private typealias Waiter = (key: ThumbnailKey, task: Task<CGImage, Error>, token: Int)

    /// A new requester of the generation in flight for `key`.
    private func join(_ key: ThumbnailKey) -> Waiter {
        nextToken += 1
        inflight[key]!.waiters.insert(nextToken)
        return (key, inflight[key]!.task, nextToken)
    }

    /// Requesters waiting for `key` now (tests).
    func waiterCount(_ key: ThumbnailKey) -> Int { inflight[key]?.waiters.count ?? 0 }

    /// The pictures of `waiters`, in order; a picture that arrived is cached. Canceling the caller leaves every key at once.
    private func collect(_ waiters: [Waiter]) async -> [Result<CGImage, any Error>] {
        await withTaskCancellationHandler {
            var out: [Result<CGImage, any Error>] = []
            for w in waiters {
                do {
                    let image = try await w.task.value
                    try Task.checkCancellation()
                    leave(w, cancel: false)
                    if lru.get(w.key) == nil { lru.put(w.key, image); saveToDisk(w.key, image) }
                    out.append(.success(image))
                } catch {
                    leave(w, cancel: false)
                    out.append(.failure(error))
                }
            }
            return out
        } onCancel: {
            Task { await self.leave(waiters, cancel: true) }
        }
    }

    private func leave(_ waiters: [Waiter], cancel: Bool) { for w in waiters { leave(w, cancel: cancel) } }

    /// A requester leaves its key (a no-op when it left already). The last one gone ends the flight, `cancel` cancels its
    /// generation; the last key of a batch gone cancels the batch (a no-op once it has finished).
    private func leave(_ w: Waiter, cancel: Bool) {
        guard var f = inflight[w.key], f.waiters.remove(w.token) != nil else { return }
        guard f.waiters.isEmpty else { inflight[w.key] = f; return }
        inflight[w.key] = nil
        if cancel { f.task.cancel() }
        guard let id = f.batch, var b = batches[id] else { return }
        b.live -= 1
        if b.live > 0 { batches[id] = b } else { batches[id] = nil; b.cancel() }
    }

    /// One generation of one time, in a slot of the lane's limiter.
    private func singleTask(url: URL, time: CMTime, height: Int, exact: Bool, lane: ThumbnailLane,
                            pixelAspect: PixelAspect?) -> Task<CGImage, Error> {
        let limiter = lane == .interactive ? interactiveLimiter : self.limiter
        return Task.detached {
            try await limiter.runThrowing {
                await self.decodeStarted()
                let made = try await Self.generate(url: url, time: time, height: height, exact: exact, shape: pixelAspect != nil)
                return await Self.shaped(made.image, url: url, known: made.shape, to: pixelAspect)
            }
        }
    }

    /// `image` redrawn in the chosen pixel aspect (F7.3); as made when none is chosen.
    private static func shaped(_ image: CGImage, url: URL, known: FileShape?, to pixelAspect: PixelAspect?) async -> CGImage {
        guard let pixelAspect else { return image }
        let file = if let known { known } else { await filePixelAspect(url) }
        return PixelAspectTag.redrawn(image, from: file.aspect, to: pixelAspect, quarterTurned: file.quarterTurned)
    }

    private func loadFromDisk(_ key: ThumbnailKey) -> CGImage? {
        guard let d = diskDirectory,
              let src = CGImageSourceCreateWithURL(d.appendingPathComponent(key.fileName) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func saveToDisk(_ key: ThumbnailKey, _ image: CGImage) {
        guard let d = diskDirectory,
              let dest = CGImageDestinationCreateWithURL(d.appendingPathComponent(key.fileName) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// The pixel aspect `generate` already applied: the track's tag for what the system image generator reads, square for
    /// stills and WebM (drawn as stored). `quarterTurned`: the track is shown turned by 90 or 270 degrees.
    typealias FileShape = (aspect: PixelAspect, quarterTurned: Bool)

    /// The shape of a file `generate` did not open as an asset itself (MXF): asks the system reader.
    private static func filePixelAspect(_ url: URL) async -> FileShape {
        if StillImage.isStill(url) || WebMFile.isWebM(url) { return (.square, false) }
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let fd = try? await track.load(.formatDescriptions).first else { return (.square, false) }
        let turn = ((try? await track.load(.preferredTransform)).map(quarterTurnRotation(of:)) ?? 0) % 180 != 0
        return (PixelAspectTag.pixelAspect(of: fd), turn)
    }

    /// The picture, and with `shape` the pixel aspect it was drawn with when that is known from the asset already open
    /// here (a second asset per poster cost 5-15 % of it; docs/PLAYBACK-PERF.md "Import: posters"). nil: `filePixelAspect`.
    private static func generate(url: URL, time: CMTime, height: Int, exact: Bool,
                                 shape: Bool) async throws -> (image: CGImage, shape: FileShape?) {
        if StillImage.isStill(url) {
            do { return (try StillImage.cgImage(of: url, maxPixel: height > 0 ? height * 4 : nil, fitHeight: height), (.square, false)) }
            catch { throw ThumbnailError.generationFailed("image: \(error)") }
        }
        if WebMFile.isWebM(url) {
            do { return (try await WebMStill.cgImage(url: url, time: time, height: height, exact: exact), (.square, false)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ThumbnailError.generationFailed("webm: \(error)") }
        }
        if MXFFile.isMXF(url) {
            do { return (try await MXFStill.cgImage(url: url, time: time, height: height, exact: exact), nil) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ThumbnailError.generationFailed("mxf: \(error)") }
        }
        let (gen, known) = try await generator(url: url, height: height, exact: exact, shape: shape)
        do {
            return (try await gen.image(at: time).image, known)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ThumbnailError.generationFailed(error.localizedDescription)
        }
    }

    /// Several times of one file in one `images(for:)` call. Each time has its own result; canceled as a whole.
    private static func generateBatch(url: URL, times: [CMTime], height: Int, exact: Bool,
                                      shape: Bool) async throws -> (images: [Result<CGImage, any Error>], shape: FileShape?) {
        let (gen, known) = try await generator(url: url, height: height, exact: exact, shape: shape)
        var out = [Result<CGImage, any Error>?](repeating: nil, count: times.count)
        for await r in gen.images(for: times) {
            if Task.isCancelled { gen.cancelAllCGImageGeneration(); throw CancellationError() }
            guard let i = times.indices.first(where: { out[$0] == nil && CMTimeCompare(times[$0], r.requestedTime) == 0 }) else { continue }
            do { out[i] = .success(try r.image) } catch { out[i] = .failure(ThumbnailError.generationFailed(error.localizedDescription)) }
        }
        try Task.checkCancellation()
        return (out.map { $0 ?? .failure(ThumbnailError.generationFailed("no picture")) }, known)
    }

    /// The asset's generator as `generate` uses it (preferred transform, tolerances, `maximumSize`), and with `shape` the
    /// pixel aspect it draws with, read from the track open here.
    private static func generator(url: URL, height: Int, exact: Bool,
                                  shape: Bool) async throws -> (AVAssetImageGenerator, FileShape?) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ThumbnailError.noVideoTrack }
        var known: FileShape?
        if shape {
            // Same reads and fallbacks as `filePixelAspect`, on the track that is open anyway.
            if let fd = try? await track.load(.formatDescriptions).first {
                let turn = ((try? await track.load(.preferredTransform)).map(quarterTurnRotation(of:)) ?? 0) % 180 != 0
                known = (PixelAspectTag.pixelAspect(of: fd), turn)
            } else {
                known = (.square, false)
            }
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if exact {
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
        }
        if height > 0 {
            // Display size after the preferred transform; keep aspect, fit to the requested pixel height.
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = natural.applying(transform)
            let w = abs(shown.width), h = abs(shown.height)
            if h > 0 { gen.maximumSize = CGSize(width: (CGFloat(height) * w / h).rounded(), height: CGFloat(height)) }
        }
        return (gen, known)
    }
}
