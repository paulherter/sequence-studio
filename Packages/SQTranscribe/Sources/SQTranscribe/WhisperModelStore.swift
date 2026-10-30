import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Whisper model file (ggml format, whisper.cpp, MIT) and where it comes from.
public struct WhisperModel: Sendable, Equatable {
    public var name: String
    public var fileName: String
    public var url: URL
    /// Exact size of the finished file: a shorter or longer download is refused.
    public var byteCount: Int64

    public init(name: String, fileName: String, url: URL, byteCount: Int64) {
        self.name = name; self.fileName = fileName; self.url = url; self.byteCount = byteCount
    }

    /// Multilingual "small", 5-bit quantized (about 181 MB): good German and English at a speed that suits a laptop CPU.
    public static let small = WhisperModel(
        name: "Whisper small", fileName: "ggml-small-q5_1.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!, byteCount: 190_085_487)
}

/// Fetches a file. The default is `URLSessionDownloader`; tests pass a fake.
public protocol ModelDownloader: Sendable {
    /// Writes the body of `url` to `file` and reports (bytes so far, total when known). Honors task cancellation.
    func download(from url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
}

/// Where the model lives and the download into that place (the Mac gets its models from the system; here they are ours).
public struct WhisperModelStore: Sendable {
    public var folder: URL
    public var model: WhisperModel

    public init(folder: URL = WhisperModelStore.defaultFolder(), model: WhisperModel = .small) {
        self.folder = folder; self.model = model
    }

    /// `SQ_WHISPER_MODELS`, else `%LOCALAPPDATA%\SequenceStudio\Whisper`, else `~/Library/Application Support/SequenceStudio/Whisper`.
    public static func defaultFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let p = environment["SQ_WHISPER_MODELS"], !p.isEmpty { return URL(fileURLWithPath: p) }
        if let p = environment["LOCALAPPDATA"], !p.isEmpty {
            return URL(fileURLWithPath: p).appendingPathComponent("SequenceStudio").appendingPathComponent("Whisper")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SequenceStudio/Whisper")
    }

    public var modelURL: URL { folder.appendingPathComponent(model.fileName) }
    public var partURL: URL { folder.appendingPathComponent(model.fileName + ".part") }

    public var isInstalled: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size]) as? NSNumber
        return size?.int64Value == model.byteCount
    }

    /// Downloads the model into the folder (`.part` file first, moved into place once the size is right).
    /// `progress` reports 0...1. A canceled or failed download leaves nothing behind.
    /// shortcut: no resume of a half download and no checksum, only the exact size; upgrade when users report broken files.
    public func install(downloader: any ModelDownloader, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.removeItem(at: partURL)
        let expected = model.byteCount
        do {
            try await downloader.download(from: model.url, to: partURL) { done, total in
                progress(min(1, max(0, Double(done) / Double(max(total ?? expected, 1)))))
            }
            let size = (try fm.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value
            guard size == expected else { throw TranscriptionError.modelDownloadFailed("the file has the wrong size") }
            try? fm.removeItem(at: modelURL)
            try fm.moveItem(at: partURL, to: modelURL)
            progress(1)
        } catch {
            try? fm.removeItem(at: partURL)
            throw error
        }
    }
}

/// `URLSession` download with progress (FoundationNetworking on Windows).
public struct URLSessionDownloader: ModelDownloader {
    public init() {}

    public func download(from url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let job = Job(destination: file, progress: progress)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                job.start(url: url, continuation: c)
            }
        } onCancel: { job.cancel() }
    }

    private final class Job: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Int64, Int64?) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var task: URLSessionDownloadTask?
        private var session: URLSession?
        private var moveError: Error?
        private var canceled = false

        init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.destination = destination; self.progress = progress
        }

        func start(url: URL, continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if canceled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session = s
            let t = s.downloadTask(with: url)
            task = t
            lock.unlock()
            t.resume()
        }

        func cancel() {
            lock.lock(); canceled = true; let t = task; lock.unlock()
            t?.cancel()
        }

        private func finish(_ error: Error?) {
            lock.lock()
            let c = continuation; continuation = nil
            let s = session; session = nil
            lock.unlock()
            s?.finishTasksAndInvalidate()
            if let error { c?.resume(throwing: error) } else { c?.resume() }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lock.lock(); moveError = TranscriptionError.modelDownloadFailed("server answered \(http.statusCode)"); lock.unlock()
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch { lock.lock(); moveError = error; lock.unlock() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let moved = moveError; let wasCanceled = canceled; lock.unlock()
            if wasCanceled { finish(CancellationError()) } else { finish(moved ?? error) }
        }
    }
}
