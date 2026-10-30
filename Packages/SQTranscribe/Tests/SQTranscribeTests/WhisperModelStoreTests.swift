import Foundation
import Testing
@testable import SQTranscribe

@Suite struct WhisperModelStoreTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sq-whisper-\(UUID().uuidString)")
    }
    private func model(bytes: Int64) -> WhisperModel {
        WhisperModel(name: "test", fileName: "ggml-test.bin", url: URL(string: "https://example.com/ggml-test.bin")!, byteCount: bytes)
    }

    struct Fake: ModelDownloader {
        var bytes: Int
        var fail = false
        func download(from url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
            try Data(count: bytes / 2).write(to: file)
            progress(Int64(bytes / 2), Int64(bytes))
            if fail { throw URLError(.notConnectedToInternet) }
            try Data(count: bytes).write(to: file)
            progress(Int64(bytes), Int64(bytes))
        }
    }

    @Test func folderComesFromTheEnvironmentThenLocalAppData() {
        #expect(WhisperModelStore.defaultFolder(environment: ["SQ_WHISPER_MODELS": "/m"]).path == "/m")
        let win = WhisperModelStore.defaultFolder(environment: ["LOCALAPPDATA": "/L"])
        #expect(win.path.hasSuffix("SequenceStudio/Whisper") && win.path.hasPrefix("/L"))
    }

    @Test func installDownloadsToAPartFileChecksTheSizeAndMovesItIntoPlace() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = WhisperModelStore(folder: dir, model: model(bytes: 1000))
        #expect(!store.isInstalled)
        let seen = Seen()
        try await store.install(downloader: Fake(bytes: 1000)) { seen.add($0) }
        #expect(store.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: store.partURL.path))
        let values = seen.values
        #expect(values.last == 1 && values == values.sorted() && values.allSatisfy { (0...1).contains($0) })
    }

    @Test func aFailedOrShortDownloadLeavesNoModelAndNoPartFile() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = WhisperModelStore(folder: dir, model: model(bytes: 1000))
        await #expect(throws: (any Error).self) { try await store.install(downloader: Fake(bytes: 1000, fail: true)) { _ in } }
        #expect(!store.isInstalled && !FileManager.default.fileExists(atPath: store.partURL.path))
        await #expect(throws: TranscriptionError.self) { try await store.install(downloader: Fake(bytes: 900)) { _ in } }
        #expect(!store.isInstalled && !FileManager.default.fileExists(atPath: store.partURL.path))
    }

    @Test func aWrongSizedFileIsNotInstalled() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = WhisperModelStore(folder: dir, model: model(bytes: 1000))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 10).write(to: store.modelURL)
        #expect(!store.isInstalled)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func add(_ v: Double) { lock.lock(); list.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return list }
}
