import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Key of one cached thumbnail. Time is quantised to microseconds so equal rational times compare equal.
public struct ThumbnailKey: Hashable, Sendable {
    public var media: UUID
    public var micros: Int64
    /// Pixel height; 0 means native size.
    public var height: Int
    public init(media: UUID, time: CMTime, height: Int) {
        self.media = media
        self.height = max(0, height)
        let t = CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero)
        self.micros = t.isValid && t.isNumeric ? t.value : 0
    }
    var fileName: String { "\(media.uuidString)_\(micros)_\(height).png" }
}

public enum ThumbnailError: Error, Sendable { case noVideoTrack, generationFailed(String) }

/// Byte-capped LRU of decoded thumbnails. Pure value logic, tested on its own.
struct ThumbnailLRU {
    private(set) var bytes = 0
    let capacity: Int
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
        guard cost <= capacity else { return }
        clock += 1
        entries[k] = (image, cost, clock); bytes += cost
        while bytes > capacity, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }) {
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
    private var inflight: [ThumbnailKey: (task: Task<CGImage, Error>, waiters: Int)] = [:]
    /// Number of AVAssetImageGenerator runs so far (for tests and diagnostics).
    public private(set) var generationCount = 0

    public init(memoryBytes: Int = 64 * 1024 * 1024, diskDirectory: URL? = nil) {
        lru = ThumbnailLRU(capacity: memoryBytes)
        self.diskDirectory = diskDirectory
        if let d = diskDirectory { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    public var cachedBytes: Int { lru.bytes }

    /// Thumbnail of `url` at `time`, scaled to `height` pixels (0 = native), preferred transform applied.
    /// `exact` decodes the precise frame; otherwise the nearest sync sample is acceptable (faster).
    public func thumbnail(media: UUID, url: URL, at time: CMTime = .zero, height: Int,
                          exact: Bool = true) async throws -> CGImage {
        let key = ThumbnailKey(media: media, time: time, height: height)
        if let hit = lru.get(key) { return hit }
        if let disk = loadFromDisk(key) { lru.put(key, disk); return disk }

        if var f = inflight[key] {
            f.waiters += 1; inflight[key] = f
        } else {
            let h = key.height
            let task = Task.detached { try await Self.generate(url: url, time: time, height: h, exact: exact) }
            inflight[key] = (task, 1)
            generationCount += 1
        }
        let task = inflight[key]!.task
        do {
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.release(key) }
            }
            try Task.checkCancellation()
            finish(key, image)
            return image
        } catch {
            finishFailed(key)
            throw error
        }
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

    private func release(_ key: ThumbnailKey) {
        guard var f = inflight[key] else { return }
        f.waiters -= 1
        if f.waiters <= 0 { f.task.cancel(); inflight[key] = nil } else { inflight[key] = f }
    }

    private func finish(_ key: ThumbnailKey, _ image: CGImage) {
        if var f = inflight[key] {
            f.waiters -= 1
            inflight[key] = f.waiters <= 0 ? nil : f
        }
        if lru.get(key) == nil {
            lru.put(key, image)
            saveToDisk(key, image)
        }
    }

    private func finishFailed(_ key: ThumbnailKey) {
        guard var f = inflight[key] else { return }
        f.waiters -= 1
        inflight[key] = f.waiters <= 0 ? nil : f
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

    private static func generate(url: URL, time: CMTime, height: Int, exact: Bool) async throws -> CGImage {
        if StillImage.isStill(url) {
            do { return try StillImage.cgImage(of: url, maxPixel: height > 0 ? height * 4 : nil, fitHeight: height) }
            catch { throw ThumbnailError.generationFailed("image: \(error)") }
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ThumbnailError.noVideoTrack }
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
        do {
            return try await gen.image(at: time).image
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ThumbnailError.generationFailed(error.localizedDescription)
        }
    }
}
