import AppKit
import AVFoundation
import ImageIO
import SQCore
import SQMedia

/// Pure maths of hover scrubbing an icon: where the pointer is inside the thumbnail picks the time in the media.
public enum HoverScrub {
    /// Time at `fraction` (0...1, clamped) of `duration`, snapped to `frameDuration`, never past the last frame.
    public static func time(fraction: Double, duration: Time, frameDuration: Time) -> Time {
        guard duration > .zero, frameDuration.value > 0 else { return .zero }
        let f = min(max(fraction, 0), 1)
        let scale: Int64 = 1_000
        let raw = Time(Int64((f * Double(scale)).rounded()) * duration.value, scale * duration.timescale)
        let last = max(.zero, duration - frameDuration)
        return min(raw.snapped(to: frameDuration), last)
    }

    /// Poster frame: 10 % into the media, at most 2 s (a clip often starts black).
    public static func poster(duration: Time, frameDuration: Time) -> Time {
        min(time(fraction: 0.1, duration: duration, frameDuration: frameDuration), Time(2, 1))
    }
}

/// Thumbnails of Project items: poster frames, hover-scrub frames and stills, cached in memory.
@MainActor
final class ProjectThumbnails {
    private let thumbnailer = Thumbnailer(memoryBytes: 48 * 1024 * 1024)
    /// Bounded: at most 400 posters / 64 MB; evicted ones are simply requested again.
    private let posters: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>()
        c.countLimit = 400; c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()
    private var failed = Set<UUID>()
    private var pending = Set<UUID>()
    private var scrubTask: Task<Void, Never>?

    func cachedPoster(_ id: UUID) -> NSImage? { posters.object(forKey: id as NSUUID) }

    func forget(_ id: UUID) {
        posters.removeObject(forKey: id as NSUUID); failed.remove(id); pending.remove(id)
        Task { await thumbnailer.invalidate(media: id) }
    }

    /// Loads the poster (async) and calls `done` on the main actor when it is there.
    func requestPoster(_ ref: MediaRef, height: Int, done: @escaping @MainActor () -> Void) {
        let id = ref.id
        guard cachedPoster(id) == nil, !failed.contains(id), pending.insert(id).inserted else { return }
        let url = URL(fileURLWithPath: ref.path)
        let still = ref.info?.isStill == true || ref.kind == .image
        let fd = ref.info?.video?.nominalFrameDuration ?? Time(1, 30)
        let total = ref.info?.duration ?? ref.duration ?? .zero
        let t = ref.posterTime ?? HoverScrub.poster(duration: total, frameDuration: fd)
        Task { [weak self, thumbnailer] in
            let cg: CGImage?
            if ref.kind == .audio { cg = nil } else if still { cg = Self.stillThumbnail(url, height: height) } else {
                cg = try? await thumbnailer.thumbnail(media: id, url: url, at: CMTime(value: t.value, timescale: Int32(clamping: t.timescale)),
                                                      height: height, exact: false)
            }
            guard let self else { return }
            pending.remove(id)
            if let cg {
                posters.setObject(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), forKey: id as NSUUID,
                                  cost: cg.bytesPerRow * cg.height)
            } else {
                if failed.count > 2000 { failed.removeAll() }
                failed.insert(id)
            }
            done()
        }
    }

    /// Hover scrub: the frame at `time`; only the newest request is delivered.
    func scrub(_ ref: MediaRef, to time: Time, height: Int, done: @escaping @MainActor (NSImage) -> Void) {
        scrubTask?.cancel()
        let url = URL(fileURLWithPath: ref.path), id = ref.id
        scrubTask = Task { [thumbnailer] in
            guard let cg = try? await thumbnailer.thumbnail(media: id, url: url, at: CMTime(value: time.value, timescale: Int32(clamping: time.timescale)),
                                                            height: height, exact: false), !Task.isCancelled else { return }
            done(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }
    }

    func cancelScrub() { scrubTask?.cancel(); scrubTask = nil }

    nonisolated private static func stillThumbnail(_ url: URL, height: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: height * 2,
        ] as CFDictionary)
    }
}
