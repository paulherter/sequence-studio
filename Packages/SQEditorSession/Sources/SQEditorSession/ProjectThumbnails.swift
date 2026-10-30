import AppKit
import AVFoundation
import ImageIO
import SQCore
import SQMedia

/// Thumbnails of Project items: poster frames, hover-scrub frames and stills, cached in memory.
/// Public for EngineBench `import-media` (it drives the same poster scheduling as the bin).
@MainActor
public final class ProjectThumbnails {
    private let limits: WorkLimits
    private let thumbnailer: Thumbnailer
    private var pressureToken: MemoryPressureToken?
    /// Items the bin shows right now (`setVisible`): kept under critical memory pressure.
    private var visible = Set<UUID>()

    /// Cache sizes from `limits` (memory audit: halved on 8 GB Macs); `pressure`: the registry the caches shrink with.
    public init(limits: WorkLimits = .current, pressure: MemoryPressureRegistry? = .shared) {
        self.limits = limits
        thumbnailer = Thumbnailer(memoryBytes: limits.thumbnailMemoryBytes, pressure: pressure)
        posters.countLimit = 400; posters.totalCostLimit = limits.posterCacheBytes
        frames.countLimit = 200; frames.totalCostLimit = limits.clipFrameCacheBytes
        pressureToken = pressure?.register("posters") { [weak self] level in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.applyMemoryPressure(level) }
            } else {
                Task { @MainActor in self?.applyMemoryPressure(level) }
            }
        }
    }

    /// Bounded: at most 400 posters / `WorkLimits.posterCacheBytes`; evicted ones are simply requested again.
    private let posters = NSCache<NSUUID, NSImage>()

    /// Posters made so far that are still cached (approx.: NSCache may have evicted some on its own).
    public var posterCount: Int { posterHeights.count }
    var posterCostLimit: Int { posters.totalCostLimit }
    var frameCostLimit: Int { frames.totalCostLimit }

    /// Memory pressure: the byte caps drop to `MemoryPressure.budget`; warning also drops every Color page clip frame,
    /// critical every poster the bin does not show. Normal restores the caps (dropped items are requested again on draw).
    func applyMemoryPressure(_ level: MemoryPressure) {
        posters.totalCostLimit = level.budget(limits.posterCacheBytes)
        frames.totalCostLimit = level.budget(limits.clipFrameCacheBytes)
        guard level != .normal else { return }
        frames.removeAllObjects()
        guard level == .critical else { return }
        for id in Array(posterHeights.keys) where !visible.contains(id) {
            posters.removeObject(forKey: id as NSUUID); posterHeights[id] = nil
        }
    }

    func storePosterForTesting(_ id: UUID, _ image: NSImage) {
        posters.setObject(image, forKey: id as NSUUID, cost: 64); posterHeights[id] = 1
    }
    func storeFrameForTesting(_ media: UUID, at t: Time, height: Int, _ image: NSImage) {
        frames.setObject(image, forKey: Self.frameKey(media, t, height) as NSString, cost: 64)
    }

    private var failed = Set<UUID>()
    /// Height (pixels) each cached poster was made at: a larger thumbnail size asks for a sharper one.
    private var posterHeights: [UUID: Int] = [:]
    private var pending = Set<UUID>()
    private var scrubTask: Task<Void, Never>?

    public func cachedPoster(_ id: UUID) -> NSImage? { posters.object(forKey: id as NSUUID) }

    /// F7.3: the pixel aspect each media item is shown with (`VideoTrackInfo.displayPixelAspect`) its pictures were last
    /// asked with. Poster, hover scrub, clip frames and stills are made in that shape, like playback and export.
    private var shapes: [UUID: PixelAspect] = [:]

    /// Sees `ref` as the project has it now. A changed pixel aspect drops the item's poster (also one still loading: its
    /// result is discarded) so the next request makes it again; clip frames are keyed by the shape.
    private func note(_ ref: MediaRef) {
        let id = ref.id, now = ref.info?.video?.displayPixelAspect
        guard shapes[id] != now else { return }
        shapes[id] = now
        posters.removeObject(forKey: id as NSUUID); posterHeights[id] = nil; failed.remove(id)
        if pending.remove(id) != nil { dropWaiting(id) }
    }

    /// Takes a poster job out of the queue (with the clip frame it carries, which is then asked for again).
    private func dropWaiting(_ id: UUID) {
        posterQueue.remove(id)
        if let key = waitingPosters.removeValue(forKey: id)?.frame?.key { pendingFrames.remove(key) }
    }

    /// The cached poster of `ref` in the shape the project gives it now; nil while it has to be made (again).
    public func poster(for ref: MediaRef) -> NSImage? { note(ref); return cachedPoster(ref.id) }

    public func forget(_ id: UUID) {
        posters.removeObject(forKey: id as NSUUID); posterHeights[id] = nil; failed.remove(id); pending.remove(id)
        shapes[id] = nil
        dropWaiting(id)
        Task { await thumbnailer.invalidate(media: id) }
    }

    /// A failed poster is tried again (the file came back online, was relinked...).
    public func clearFailure(_ id: UUID) { failed.remove(id) }

    /// Loads the poster (async) and calls `done` on the main actor when it is there. A cached poster is kept unless
    /// the wanted height is clearly larger than the one it was made at. Requests wait in a `VisibleFirstQueue`: at most
    /// `WorkLimits.posterDecodes` load at once, items on screen (`setVisible`) first, then the rest oldest first, so a
    /// fresh import of hundreds of clips shows the posters the user is looking at before the ones scrolled away.
    public func requestPoster(_ ref: MediaRef, height: Int, done: @escaping @MainActor () -> Void) {
        let id = ref.id
        note(ref)
        if cachedPoster(id) != nil, let have = posterHeights[id], have * 4 >= height * 3 { return }
        guard !failed.contains(id), pending.insert(id).inserted else { return }
        if ref.kind == .audio {           // no picture: settled at once, no decode slot
            pending.remove(id)
            failed.insert(id)
            Task { done() }
            return
        }
        waitingPosters[id] = (ref, height, done, nil)
        posterQueue.enqueue(id)
        pumpPosters()
    }

    /// The poster and the clip frame at `t` of `ref` (Color page Clips list). When both have to be made they wait as ONE
    /// job in the poster queue (visible first, `posterDecodes` wide) and decode in one generator call: two frames of one
    /// file that way cost 0.70-0.85 of two calls (docs/PLAYBACK-PERF.md "Import: posters, per variant"). Otherwise each
    /// goes its own way. `done` fires once per picture that arrives.
    public func requestPosterAndFrame(_ ref: MediaRef, frameAt t: Time?, height: Int, done: @escaping @MainActor () -> Void) {
        let id = ref.id
        note(ref)
        guard let t, ref.kind != .audio, ref.kind != .image, ref.info?.isStill != true else {
            requestPoster(ref, height: height, done: done)
            if let t { requestFrame(ref, at: t, height: height, done: done) }
            return
        }
        let key = shapedKey(id, t, height)
        let posterWanted = !(cachedPoster(id) != nil && (posterHeights[id] ?? 0) * 4 >= height * 3)
            && !failed.contains(id) && !pending.contains(id)
        let frameWanted = frames.object(forKey: key as NSString) == nil && !failedFrames.contains(key) && !pendingFrames.contains(key)
        guard posterWanted, frameWanted else {
            requestPoster(ref, height: height, done: done)
            requestFrame(ref, at: t, height: height, done: done)
            return
        }
        pending.insert(id); pendingFrames.insert(key)
        waitingPosters[id] = (ref, height, done, (t, key))
        posterQueue.enqueue(id)
        pumpPosters()
    }

    /// Media on screen now, top-left first: their posters load before any other waiting one.
    public func setVisible(_ ids: [UUID]) { visible = Set(ids); posterQueue.setVisible(ids) }

    private var posterQueue = VisibleFirstQueue<UUID>()
    private var waitingPosters: [UUID: (ref: MediaRef, height: Int, done: @MainActor () -> Void, frame: (t: Time, key: String)?)] = [:]
    private var runningPosters = 0
    private let posterWidth = WorkLimits.current.posterDecodes

    private func pumpPosters() {
        while runningPosters < posterWidth, let id = posterQueue.next() {
            guard let job = waitingPosters.removeValue(forKey: id) else { continue }
            runningPosters += 1
            if let frame = job.frame { loadPosterAndFrame(job.ref, frame: frame, height: job.height, done: job.done) }
            else { loadPoster(job.ref, height: job.height, done: job.done) }
        }
    }

    /// One generator call for the poster and one clip frame of `ref` (both wanted, a video file).
    private func loadPosterAndFrame(_ ref: MediaRef, frame: (t: Time, key: String), height: Int, done: @escaping @MainActor () -> Void) {
        let id = ref.id
        let url = URL(fileURLWithPath: ref.path)
        let fd = ref.info?.video?.nominalFrameDuration ?? Time(1, 30)
        let total = ref.info?.duration ?? ref.duration ?? .zero
        let pt = ref.posterTime ?? HoverScrub.poster(duration: total, frameDuration: fd)
        let aspect = ref.info?.video?.displayPixelAspect
        let times = [pt, frame.t].map { CMTime(value: $0.value, timescale: Int32(clamping: $0.timescale)) }
        Task { [weak self, thumbnailer] in
            let got = await thumbnailer.thumbnails(media: id, url: url, at: times, height: height, exact: false, pixelAspect: aspect)
            guard let self else { return }
            runningPosters -= 1
            defer { pumpPosters() }
            pendingFrames.remove(frame.key)
            if let cg = try? got[1].get() {
                frames.setObject(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), forKey: frame.key as NSString,
                                 cost: cg.bytesPerRow * cg.height)
            } else {
                if failedFrames.count > 2000 { failedFrames.removeAll() }
                failedFrames.insert(frame.key)
            }
            defer { done() }
            guard shapes[id] == aspect else { return }      // the pixel aspect changed meanwhile: a new load is on its way
            pending.remove(id)
            if let cg = try? got[0].get() {
                posterHeights[id] = height
                posters.setObject(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), forKey: id as NSUUID,
                                  cost: cg.bytesPerRow * cg.height)
            } else {
                if failed.count > 2000 { failed.removeAll() }
                failed.insert(id)
            }
        }
    }

    private func loadPoster(_ ref: MediaRef, height: Int, done: @escaping @MainActor () -> Void) {
        let id = ref.id
        let url = URL(fileURLWithPath: ref.path)
        let still = ref.info?.isStill == true || ref.kind == .image
        let fd = ref.info?.video?.nominalFrameDuration ?? Time(1, 30)
        let total = ref.info?.duration ?? ref.duration ?? .zero
        let t = ref.posterTime ?? HoverScrub.poster(duration: total, frameDuration: fd)
        let aspect = ref.info?.video?.displayPixelAspect
        Task { [weak self, thumbnailer] in
            let cg: CGImage?
            if still {
                // A still is drawn as stored (square): the chosen shape is applied to the picture.
                cg = await Self.stillThumbnail(url, height: height).map { i in aspect.map { PixelAspectTag.redrawn(i, from: .square, to: $0) } ?? i }
            } else {
                cg = try? await thumbnailer.thumbnail(media: id, url: url, at: CMTime(value: t.value, timescale: Int32(clamping: t.timescale)),
                                                      height: height, exact: false, pixelAspect: aspect)
            }
            guard let self else { return }
            runningPosters -= 1
            defer { pumpPosters() }
            guard shapes[id] == aspect else { return }      // the pixel aspect changed meanwhile: a new load is on its way
            pending.remove(id)
            if let cg {
                posterHeights[id] = height
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
    public func scrub(_ ref: MediaRef, to time: Time, height: Int, done: @escaping @MainActor (NSImage) -> Void) {
        note(ref)
        scrubTask?.cancel()
        let url = URL(fileURLWithPath: ref.path), id = ref.id
        let aspect = ref.info?.video?.displayPixelAspect
        scrubTask = Task { [thumbnailer] in
            guard let cg = try? await thumbnailer.thumbnail(media: id, url: url, at: CMTime(value: time.value, timescale: Int32(clamping: time.timescale)),
                                                            height: height, exact: false, lane: .interactive, pixelAspect: aspect),
                  !Task.isCancelled else { return }
            done(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }
    }

    // MARK: Clip frames (Color page Clips list)

    /// Frames of single clips, keyed by media + time + height. Bounded: at most 200 frames / `WorkLimits.clipFrameCacheBytes`;
    /// evicted ones are requested again.
    private let frames = NSCache<NSString, NSImage>()
    private var pendingFrames = Set<String>()
    private var failedFrames = Set<String>()

    static func frameKey(_ media: UUID, _ t: Time, _ height: Int) -> String { "\(media.uuidString)|\(t.value)/\(t.timescale)|\(height)" }

    /// Cache key of a clip frame in the shape `media` is shown with now (the plain key for the file's own shape).
    private func shapedKey(_ media: UUID, _ t: Time, _ height: Int) -> String {
        let k = Self.frameKey(media, t, height)
        return shapes[media].map { "\(k)|\($0.num):\($0.den)" } ?? k
    }

    public func cachedFrame(_ media: UUID, at t: Time, height: Int) -> NSImage? { frames.object(forKey: shapedKey(media, t, height) as NSString) }

    /// The frame of `ref` at `t` (media time), loaded off the main thread; `done` fires on the main actor once it is cached.
    /// Stills and audio have no per-clip frame (callers keep the poster).
    func requestFrame(_ ref: MediaRef, at t: Time, height: Int, done: @escaping @MainActor () -> Void) {
        guard ref.kind != .audio, ref.kind != .image, ref.info?.isStill != true else { return }
        note(ref)
        let key = shapedKey(ref.id, t, height), aspect = ref.info?.video?.displayPixelAspect
        guard frames.object(forKey: key as NSString) == nil, !failedFrames.contains(key), pendingFrames.insert(key).inserted else { return }
        let url = URL(fileURLWithPath: ref.path), id = ref.id
        Task { [weak self, thumbnailer] in
            let cg = try? await thumbnailer.thumbnail(media: id, url: url, at: CMTime(value: t.value, timescale: Int32(clamping: t.timescale)),
                                                      height: height, exact: false, pixelAspect: aspect)
            guard let self else { return }
            pendingFrames.remove(key)
            if let cg {
                frames.setObject(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), forKey: key as NSString,
                                 cost: cg.bytesPerRow * cg.height)
            } else {
                if failedFrames.count > 2000 { failedFrames.removeAll() }
                failedFrames.insert(key)
            }
            done()
        }
    }

    public func cancelScrub() { scrubTask?.cancel(); scrubTask = nil }

    /// Decoding a big photo takes long: off the main actor.
    @concurrent private static func stillThumbnail(_ url: URL, height: Int) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: height * 2,
        ] as CFDictionary)
    }
}
