import Foundation
import SSCore

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

    public init(id: UUID = UUID(), name: String, settings: ExportSettings, outputDirectory: URL,
                makeSources: @escaping @Sendable () async throws -> ExportSources) {
        self.id = id; self.name = name; self.settings = settings; self.outputDirectory = outputDirectory
        self.makeSources = makeSources
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
}

public actor ExportQueue {
    public typealias Update = ExportJobStatus

    private struct Entry { var job: ExportJob; var status: ExportJobStatus }
    private var entries: [Entry] = []
    /// Lowercased paths (case-insensitive file systems): video and sidecar names.
    private var reserved = Set<String>()
    private var runningTask: Task<[SRTCue], Error>?
    private var runningID: UUID?
    private var cancelRequested = Set<UUID>()
    private var isRunning = false
    private var continuations: [UUID: AsyncStream<Update>.Continuation] = [:]

    public init() {}

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
        let sidecarExt = job.settings.captions == .sidecarSRT ? "srt" : nil
        let url = uniqueURL(directory: job.outputDirectory, name: job.name, ext: job.settings.fileExtension, alsoExt: sidecarExt)
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
            unreserve(entries[i].status.outputURL, sidecar: entries[i].job.settings.captions == .sidecarSRT)
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
        defer { isRunning = false }
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
        let task = Task<[SRTCue], Error> {
            let src = try await job.makeSources()
            try await ExportWriter.export(video: src.video, audio: src.audio, settings: job.settings, to: url) { p in
                Task { await queue.setProgress(id, p) }
            }
            return src.captions
        }
        runningTask = task
        // Cancellation requested before the task was stored.
        if cancelRequested.contains(id) { task.cancel() }
        let result = await task.result
        runningTask = nil; runningID = nil
        switch result {
        case .success(let captions):
            // The video is finished; a sidecar problem never deletes it.
            if job.settings.captions == .sidecarSRT {
                let srt = url.deletingPathExtension().appendingPathExtension("srt")
                do {
                    try SRTWriter.write(captions, range: job.settings.range, to: srt)
                    update(id) { $0.sidecarURL = srt }
                } catch {
                    update(id) { $0.sidecarError = "\(error)" }
                }
            }
            update(id) { $0.progress = 1.0; $0.state = .done(url) }
        case .failure(let e):
            try? FileManager.default.removeItem(at: url)
            unreserve(url, sidecar: job.settings.captions == .sidecarSRT)
            if e is CancellationError || cancelRequested.contains(id) {
                update(id) { $0.state = .cancelled }
            } else {
                update(id) { $0.state = .failed("\(e)") }
            }
        }
        cancelRequested.remove(id)
    }

    private static func key(_ u: URL) -> String { u.standardizedFileURL.path.lowercased() }

    private func unreserve(_ url: URL, sidecar: Bool) {
        reserved.remove(Self.key(url))
        if sidecar { reserved.remove(Self.key(url.deletingPathExtension().appendingPathExtension("srt"))) }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        // Late progress callbacks must not move a finished job or go backwards.
        guard let s = status(id), s.state == .running, p > s.progress else { return }
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
            let url = directory.appendingPathComponent("\(stem).\(ext)")
            var candidates = [url]
            if let e = alsoExt { candidates.append(directory.appendingPathComponent("\(stem).\(e)")) }
            // fileExists is case-insensitive on APFS; `reserved` is lowercased for queued jobs.
            if candidates.allSatisfy({ !reserved.contains(Self.key($0)) && !FileManager.default.fileExists(atPath: $0.path) }) { return url }
            n += 1
        }
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let s = name.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.hasPrefix(".") ? "Export" + s : s
    }
}
