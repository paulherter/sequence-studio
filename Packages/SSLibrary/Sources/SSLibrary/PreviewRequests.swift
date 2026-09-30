import Foundation

public enum PreviewKind: String, Codable, Sendable, CaseIterable {
    case thumbnail, waveform

    var fileExtension: String { self == .thumbnail ? "png" : "waveform" }
}

/// Identifies a file version: path + modification time + size.
public struct ContentHash: Codable, Sendable, Hashable {
    public var path: String
    public var modified: Date
    public var size: Int64

    public init(path: String, modified: Date, size: Int64) {
        self.path = path
        self.modified = modified
        self.size = size
    }

    /// Stable 16 hex digit key (FNV-1a 64; `hashValue` is per-process so unusable on disk).
    public var key: String {
        let millis = Int64((modified.timeIntervalSince1970 * 1000).rounded())
        var h: UInt64 = 0xcbf29ce484222325
        for byte in "\(path)|\(millis)|\(size)".utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

public struct PreviewRequest: Sendable, Hashable {
    public var entryID: LibraryEntryID
    public var kind: PreviewKind
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var contentHash: ContentHash

    public init(entryID: LibraryEntryID, kind: PreviewKind, pixelWidth: Int, pixelHeight: Int, contentHash: ContentHash) {
        self.entryID = entryID
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.contentHash = contentHash
    }

    public init(entry: LibraryEntry, in folder: WatchedFolder, kind: PreviewKind, pixelWidth: Int, pixelHeight: Int) {
        self.init(
            entryID: entry.id, kind: kind, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            contentHash: ContentHash(path: entry.url(in: folder).path, modified: entry.modified, size: entry.size))
    }

    /// Unique key of the rendered result (content + kind + size); the entry id is not part of it.
    var cacheKey: String { "\(contentHash.key)_\(pixelWidth)x\(pixelHeight)" }
}

public enum PreviewError: Error, Equatable, Sendable {
    /// The file changed while the preview was being generated.
    case stale
}

/// Generates a preview file at `destination`. Implemented elsewhere (AVFoundation); must honor task cancellation.
public protocol PreviewProvider: Sendable {
    func generate(_ request: PreviewRequest, to destination: URL) async throws
}

/// Derives cache file locations: `<caches>/Sequence Studio/Previews/<kind>/<key>.<ext>`.
public struct PreviewCache: Sendable {
    public let root: URL

    public init(cachesDirectory: URL) {
        root = cachesDirectory.appendingPathComponent("Sequence Studio", isDirectory: true)
            .appendingPathComponent("Previews", isDirectory: true)
    }

    public static func defaultCachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    public func fileURL(for request: PreviewRequest) -> URL {
        root.appendingPathComponent(request.kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(request.cacheKey).\(request.kind.fileExtension)")
    }
}

/// Serves previews from cache, de-duplicates identical in-flight requests and drops stale work.
public actor PreviewCoordinator {
    private struct Slot: Hashable { var entryID: LibraryEntryID; var kind: PreviewKind }
    private struct Flight {
        var id: UUID
        var task: Task<URL, any Error>
        var waiters: Int
        var slot: Slot
        var contentKey: String
        var superseded = false
    }

    private let cache: PreviewCache
    private let provider: any PreviewProvider
    private var flights: [String: Flight] = [:]
    private var latestContent: [Slot: String] = [:]
    private var knownFiles: [Slot: [String: Set<URL>]] = [:]

    public init(cache: PreviewCache, provider: any PreviewProvider) {
        self.cache = cache
        self.provider = provider
    }

    public var inFlightCount: Int { flights.count }
    public func waiterCount(for request: PreviewRequest) -> Int { flights[flightKey(request)]?.waiters ?? 0 }

    private func flightKey(_ r: PreviewRequest) -> String { "\(r.kind.rawValue)/\(r.cacheKey)" }

    public func preview(for request: PreviewRequest) async throws -> URL {
        let slot = Slot(entryID: request.entryID, kind: request.kind)
        let content = request.contentHash.key
        if let latest = latestContent[slot], latest != content { supersede(slot, keeping: content) }
        latestContent[slot] = content

        let destination = cache.fileURL(for: request)
        if FileManager.default.fileExists(atPath: destination.path) {
            knownFiles[slot, default: [:]][content, default: []].insert(destination)
            return destination
        }

        let key = flightKey(request)
        let id: UUID
        let task: Task<URL, any Error>
        if var existing = flights[key] {
            existing.waiters += 1
            flights[key] = existing
            id = existing.id
            task = existing.task
        } else {
            id = UUID()
            task = makeTask(request: request, key: key, id: id, destination: destination)
            flights[key] = Flight(id: id, task: task, waiters: 1, slot: slot, contentKey: content)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.leave(key: key, id: id) }
        }
    }

    private func makeTask(request: PreviewRequest, key: String, id: UUID, destination: URL) -> Task<URL, any Error> {
        let provider = provider
        return Task {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temp = destination.deletingLastPathComponent().appendingPathComponent(".tmp-\(id.uuidString)")
                defer { try? FileManager.default.removeItem(at: temp) }
                try await provider.generate(request, to: temp)
                try Task.checkCancellation()
                if await self.isSuperseded(key: key, id: id) { throw PreviewError.stale }
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temp, to: destination)
                await self.finish(key: key, id: id, request: request, destination: destination)
                return destination
            } catch {
                let wasSuperseded = await self.isSuperseded(key: key, id: id)
                await self.finish(key: key, id: id, request: nil, destination: nil)
                throw wasSuperseded ? PreviewError.stale : error
            }
        }
    }

    private func isSuperseded(key: String, id: UUID) -> Bool {
        guard let f = flights[key], f.id == id else { return false }
        return f.superseded
    }

    private func finish(key: String, id: UUID, request: PreviewRequest?, destination: URL?) {
        guard let f = flights[key], f.id == id else { return }
        flights[key] = nil
        if let request, let destination, !f.superseded {
            knownFiles[f.slot, default: [:]][request.contentHash.key, default: []].insert(destination)
        }
    }

    private func leave(key: String, id: UUID) {
        guard var f = flights[key], f.id == id else { return }
        f.waiters -= 1
        if f.waiters <= 0 {
            flights[key] = nil
            f.task.cancel()
        } else {
            flights[key] = f
        }
    }

    /// Cancels work and deletes cached files of older content versions of the same entry/kind.
    private func supersede(_ slot: Slot, keeping content: String) {
        for (key, var f) in flights where f.slot == slot && f.contentKey != content {
            f.superseded = true
            flights[key] = f
            f.task.cancel()
        }
        if let byContent = knownFiles[slot] {
            for (oldContent, urls) in byContent where oldContent != content {
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            knownFiles[slot] = byContent.filter { $0.key == content }
        }
    }
}
