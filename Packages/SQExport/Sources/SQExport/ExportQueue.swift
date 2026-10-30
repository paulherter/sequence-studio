import Foundation
import SQCore

public struct ExportSources: Sendable {
    public var video: any FrameSource
    public var audio: (any AudioSource)?
    /// Cues on the sequence timeline; written as sidecar when `settings.captions == .sidecarSRT`.
    public var captions: [SRTCue]
    public init(video: any FrameSource, audio: (any AudioSource)? = nil, captions: [SRTCue] = []) {
        self.video = video; self.audio = audio; self.captions = captions
    }
}

/// One sequence to export. Sources are created lazily when the job starts.
public struct ExportJob: Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var settings: ExportSettings
    public var outputDirectory: URL
    public var makeSources: @Sendable () async throws -> ExportSources
    /// The user chose Replace for an existing file of this name: the queue keeps the exact name instead of adding " 2".
    public var replaceExisting = false

    public init(id: UUID = UUID(), name: String, settings: ExportSettings, outputDirectory: URL,
                makeSources: @escaping @Sendable () async throws -> ExportSources) {
        self.id = id; self.name = name; self.settings = settings; self.outputDirectory = outputDirectory
        self.makeSources = makeSources
    }
}

extension ExportJob {
    /// "Export all formats" (W5.1): one job for the sequence's own format and one per variant, in variant order. A
    /// variant job is named "<name> <variant name>" (the queue turns that into the file name), carries the variant id in
    /// `settings.variant` and is sized like the variant at the same scale the base export uses (`settings` relative to
    /// `timeline.format`, rounded to even pixels). `makeSources` is called with each job's own settings.
    public static func variantJobs(name: String, settings: ExportSettings, outputDirectory: URL, timeline: Timeline,
                                   makeSources: @escaping @Sendable (ExportSettings) async throws -> ExportSources) -> [ExportJob] {
        var base = settings
        base.variant = nil
        let first = base
        var out = [ExportJob(name: name, settings: first, outputDirectory: outputDirectory) { try await makeSources(first) }]
        let seq = timeline.format
        // The export carries the sequence's Pixel Shape: sizes are stored sizes. Exported with another shape (a square
        // preset on a non-square sequence) the picture is the display canvas, so sizes follow display widths.
        let sameShape = settings.video.pixelAspect == seq.pixelAspect
        let bw = max(sameShape ? seq.width : seq.displayWidth, 1)
        for v in timeline.variants {
            var s = base
            s.variant = v.id
            let vf = v.format(base: seq)
            s.video.pixelAspect = sameShape ? vf.pixelAspect : settings.video.pixelAspect
            let vw = sameShape ? vf.width : vf.displayWidth
            s.video.width = evenScaled(vw, settings.video.width, bw)
            s.video.height = evenScaled(vf.height, settings.video.width, bw)
            let js = s
            out.append(ExportJob(name: "\(name) \(v.name)", settings: js, outputDirectory: outputDirectory) { try await makeSources(js) })
        }
        return out
    }

    /// `value * num / den` rounded to the nearest even integer, at least 2 (integer math, no Double).
    static func evenScaled(_ value: Int, _ num: Int, _ den: Int) -> Int {
        let twice = (2 * value * num + den) / (2 * den)          // round(value * num / den)
        return max(2, (twice + 1) / 2 * 2)
    }
}

public enum ExportJobState: Sendable, Equatable {
    case waiting, running, done(URL), failed(String), cancelled
}

public struct ExportJobStatus: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var state: ExportJobState
    public var progress: Double
    public var outputURL: URL
    /// Set once the sidecar .srt has been written next to the video.
    public var sidecarURL: URL? = nil
    /// Set when the video finished but the sidecar could not be written; the video is kept.
    public var sidecarError: String? = nil
    /// Set once the cover image has been written next to the video (`settings.coverImage`).
    public var coverURL: URL? = nil
    /// Set when the video finished but the cover image could not be written; the video is kept.
    public var coverError: String? = nil
    /// Set when the export normalized loudness: measured and resulting levels.
    public var loudness: LoudnessReport? = nil
}

public actor ExportQueue {
    public typealias Update = ExportJobStatus

    private struct Entry { var job: ExportJob; var status: ExportJobStatus }
    private var entries: [Entry] = []
    /// Lowercased paths (case-insensitive file systems): video and sidecar names.
    private var reserved = Set<String>()
    private var runningTask: Task<(captions: [SRTCue], loudness: LoudnessReport?, cover: Result<URL, Error>?), Error>?
    private var runningID: UUID?
    private var cancelRequested = Set<UUID>()
    private var isRunning = false
    /// Publishes at most 10 progress updates per second per job (the writer reports per frame).
    private var throttles: [UUID: ProgressThrottle] = [:]
    private var continuations: [UUID: AsyncStream<Update>.Continuation] = [:]

    /// Free bytes on a folder's volume (nil = unknown); injected so tests need no full disk.
    private let freeSpaceProbe: @Sendable (URL) -> Int64?
    /// The running export stops cleanly when the output volume has less than this left.
    private let minimumFreeBytes: Int64
    private let checkInterval: Duration
    private var lowSpaceStops = Set<UUID>()
    /// Writes the files: `AVExportEncoder` on the Mac, the FFmpeg encoder (SQMediaFFmpeg) on Windows.
    private let encoder: any ExportEncoding

    #if canImport(AVFoundation)
    public init(freeSpaceProbe: @escaping @Sendable (URL) -> Int64? = { ExportPreflight.freeBytes(at: $0) },
                minimumFreeBytes: Int64 = ExportPreflight.runningFloorBytes, checkInterval: Duration = .seconds(2)) {
        self.init(encoder: AVExportEncoder(), freeSpaceProbe: freeSpaceProbe, minimumFreeBytes: minimumFreeBytes,
                  checkInterval: checkInterval)
    }
    #endif

    public init(encoder: any ExportEncoding, freeSpaceProbe: @escaping @Sendable (URL) -> Int64? = { ExportPreflight.freeBytes(at: $0) },
                minimumFreeBytes: Int64 = ExportPreflight.runningFloorBytes, checkInterval: Duration = .seconds(2)) {
        self.encoder = encoder
        self.freeSpaceProbe = freeSpaceProbe
        self.minimumFreeBytes = minimumFreeBytes
        self.checkInterval = checkInterval
    }

    // MARK: Observation

    public func updates() -> AsyncStream<Update> {
        let key = UUID()
        let (stream, cont) = AsyncStream<Update>.makeStream(bufferingPolicy: .unbounded)
        continuations[key] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.removeContinuation(key) } }
        return stream
    }
    private func removeContinuation(_ k: UUID) { continuations[k] = nil }

    public func status(_ id: UUID) -> ExportJobStatus? { entries.first { $0.job.id == id }?.status }
    public func allStatuses() -> [ExportJobStatus] { entries.map(\.status) }

    // MARK: Control

    @discardableResult
    public func enqueue(_ job: ExportJob) -> UUID {
        let sidecarExt = job.settings.captions.sidecarExtension
        var chosen: URL? = nil
        if job.replaceExisting {
            let exact = job.outputDirectory.appendingPathComponent(Self.fileName(Self.sanitize(job.name), ext: job.settings.fileExtension))
            var all = [exact]
            if let e = sidecarExt { all.append(exact.deletingPathExtension().appendingPathExtension(e)) }
            if all.allSatisfy({ !reserved.contains(Self.key($0)) }) { chosen = exact }
        }
        let url = chosen ?? uniqueURL(directory: job.outputDirectory, name: job.name, ext: job.settings.fileExtension, alsoExt: sidecarExt)
        reserved.insert(Self.key(url))
        if let e = sidecarExt { reserved.insert(Self.key(url.deletingPathExtension().appendingPathExtension(e))) }
        let st = ExportJobStatus(id: job.id, name: job.name, state: .waiting, progress: 0, outputURL: url)
        entries.append(Entry(job: job, status: st))
        publish(st)
        return job.id
    }

    public func cancel(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.job.id == id }) else { return }
        switch entries[i].status.state {
        case .waiting:
            entries[i].status.state = .cancelled
            unreserve(entries[i].status.outputURL, sidecarExt: entries[i].job.settings.captions.sidecarExtension)
            publish(entries[i].status)
        case .running:
            cancelRequested.insert(id)
            runningTask?.cancel()
        default: break
        }
    }

    /// Runs all waiting jobs one after another (also jobs added meanwhile). Returns when none are waiting.
    public func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        // A long export must not be cut short by idle system sleep (the display may still sleep).
        #if canImport(Darwin)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Exporting video")
        defer { ProcessInfo.processInfo.endActivity(activity); isRunning = false }
        #else
        // shortcut: no sleep assertion off the Mac; upgrade with SetThreadExecutionState on Windows.
        defer { isRunning = false }
        #endif
        while let i = entries.firstIndex(where: { $0.status.state == .waiting }) {
            await run(index: i)
        }
    }

    // MARK: Internals

    private func run(index i: Int) async {
        let job = entries[i].job
        let id = job.id
        let url = entries[i].status.outputURL
        update(id) { $0.state = .running }
        runningID = id
        let queue = self
        let encoder = self.encoder
        // An audio-only file carries no burned-in captions and no cover image.
        let settings = job.settings.forDelivery
        let task = Task<(captions: [SRTCue], loudness: LoudnessReport?, cover: Result<URL, Error>?), Error> {
            let src = try await job.makeSources()
            let report = try await encoder.export(video: src.video, audio: src.audio, settings: settings, to: url) { p in
                Task { await queue.setProgress(id, p) }
            }
            // The video is finished; a cover problem never deletes it.
            var cover: Result<URL, Error>? = nil
            if let format = settings.coverImage {
                do { cover = .success(try await Self.writeCover(from: src.video, settings: settings, format: format, videoURL: url)) }
                catch { cover = .failure(error) }
            }
            return (src.captions, report, cover)
        }
        runningTask = task
        // Free-space watch: a volume that fills up mid-export stops the job with a clear message (and removes the partial
        // file) instead of letting the encoder fail on a write.
        let folder = url.deletingLastPathComponent()
        let probe = freeSpaceProbe, floor = minimumFreeBytes, interval = checkInterval
        let watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                if let free = probe(folder), free < floor {
                    await queue.stopForLowSpace(id)
                    return
                }
            }
        }
        defer { watch.cancel() }
        // Cancellation requested before the task was stored.
        if cancelRequested.contains(id) { task.cancel() }
        let result = await task.result
        runningTask = nil; runningID = nil
        switch result {
        case .success(let done):
            let captions = done.captions
            if let report = done.loudness { update(id) { $0.loudness = report } }
            switch done.cover {
            case .success(let cover)?: update(id) { $0.coverURL = cover }
            case .failure(let error)?: update(id) { $0.coverError = "\(error)" }
            case nil: break
            }
            // The video is finished; a sidecar problem never deletes it.
            if let ext = job.settings.captions.sidecarExtension {
                let srt = url.deletingPathExtension().appendingPathExtension(ext)
                do {
                    try job.settings.captions.writeSidecar(captions, range: job.settings.range, to: srt)
                    update(id) { $0.sidecarURL = srt }
                } catch {
                    update(id) { $0.sidecarError = "\(error)" }
                }
            }
            update(id) { $0.progress = 1.0; $0.state = .done(url) }
        case .failure(let e):
            try? FileManager.default.removeItem(at: url)
            unreserve(url, sidecarExt: job.settings.captions.sidecarExtension)
            if lowSpaceStops.contains(id) {
                lowSpaceStops.remove(id)
                update(id) { $0.state = .failed(ExportPreflight.ranOutOfSpaceMessage(freeBytes: ExportPreflight.freeBytes(at: url.deletingLastPathComponent()))) }
            } else if e is CancellationError || cancelRequested.contains(id) {
                update(id) { $0.state = .cancelled }
            } else {
                let free = ExportPreflight.freeBytes(at: url.deletingLastPathComponent())
                update(id) { $0.state = .failed(ExportPreflight.failureMessage(e, freeBytes: free)) }
            }
        }
        cancelRequested.remove(id)
        throttles[id] = nil
    }

    fileprivate func stopForLowSpace(_ id: UUID) {
        guard runningID == id else { return }
        lowSpaceStops.insert(id)
        runningTask?.cancel()
    }

    /// Saves the cover frame ("Cover" marker time, else the first frame) as "<video name> Cover.<ext>" next to the video.
    private static func writeCover(from video: any FrameSource, settings: ExportSettings, format: CoverImageFormat, videoURL: URL) async throws -> URL {
        let start: Time
        if case .inOut(let r) = settings.range { start = r.start } else { start = .zero }
        let index = CoverFrame.frameIndex(time: settings.coverTime, rangeStart: start, frameDuration: video.frameDuration,
                                          frameCount: video.frameCount)
        let frame = try await video.frame(at: index)
        let dir = videoURL.deletingLastPathComponent()
        let stem = videoURL.deletingPathExtension().lastPathComponent
        var n = 1
        var url: URL
        repeat {
            url = dir.appendingPathComponent(CoverFrame.fileName(videoStem: n == 1 ? stem : "\(stem) \(n)", ext: format.fileExtension))
            n += 1
        } while FileManager.default.fileExists(atPath: url.path)
        #if canImport(AVFoundation)
        try CoverImageWriter.write(frame, format: format, pixelAspect: settings.video.pixelAspect, to: url)
        return url
        #else
        // shortcut: no cover image off the Mac; upgrade when SQMediaFFmpeg writes stills.
        _ = frame
        throw ExportError.writerFailed("Cover images are not available on this platform yet")
        #endif
    }

    private static func key(_ u: URL) -> String { u.standardizedFileURL.path.lowercased() }

    private func unreserve(_ url: URL, sidecarExt: String?) {
        reserved.remove(Self.key(url))
        if let e = sidecarExt { reserved.remove(Self.key(url.deletingPathExtension().appendingPathExtension(e))) }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        // Late progress callbacks must not move a finished job or go backwards.
        guard let s = status(id), s.state == .running, p > s.progress else { return }
        var th = throttles[id] ?? ProgressThrottle(minInterval: 0.1)
        let pass = th.accept(progress: p, at: ProcessInfo.processInfo.systemUptime)
        throttles[id] = th
        guard pass else { return }
        update(id) { $0.progress = p }
    }

    private func update(_ id: UUID, _ f: (inout ExportJobStatus) -> Void) {
        guard let i = entries.firstIndex(where: { $0.job.id == id }) else { return }
        f(&entries[i].status)
        publish(entries[i].status)
    }

    private func publish(_ s: ExportJobStatus) { for c in continuations.values { c.yield(s) } }

    private func uniqueURL(directory: URL, name: String, ext: String, alsoExt: String?) -> URL {
        let base = Self.sanitize(name)
        var n = 1
        while true {
            let stem = n == 1 ? base : "\(base) \(n)"
            let url = directory.appendingPathComponent(Self.fileName(stem, ext: ext))
            var candidates = [url]
            if let e = alsoExt { candidates.append(directory.appendingPathComponent("\(stem).\(e)")) }
            // fileExists is case-insensitive on APFS; `reserved` is lowercased for queued jobs.
            if candidates.allSatisfy({ !reserved.contains(Self.key($0)) && !FileManager.default.fileExists(atPath: $0.path) }) { return url }
            n += 1
        }
    }

    /// "stem.ext"; an empty extension (an image sequence folder) is just the stem.
    static func fileName(_ stem: String, ext: String) -> String { ext.isEmpty ? stem : "\(stem).\(ext)" }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let s = name.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.hasPrefix(".") ? "Export" + s : s
    }
}
