import Foundation
import CoreServices

/// Cancels a running watch. Idempotent.
public protocol FolderWatchToken: Sendable {
    func cancel()
}

/// Reports "something changed under this folder" (coalesced by the implementation).
public protocol FolderWatching: Sendable {
    func watch(_ url: URL, onChange: @escaping @Sendable () -> Void) -> any FolderWatchToken
}

/// Test double: call `fire(url)` to simulate a change.
public final class FakeFolderWatcher: FolderWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: (URL, @Sendable () -> Void)] = [:]

    public init() {}

    public var activeCount: Int { lock.withLock { handlers.count } }

    public func fire(_ url: URL) {
        let targets = lock.withLock { handlers.values.filter { $0.0 == url }.map(\.1) }
        targets.forEach { $0() }
    }

    public func watch(_ url: URL, onChange: @escaping @Sendable () -> Void) -> any FolderWatchToken {
        let id = UUID()
        lock.withLock { handlers[id] = (url, onChange) }
        return Token { [weak self] in _ = self?.lock.withLock { self?.handlers.removeValue(forKey: id) } }
    }

    private struct Token: FolderWatchToken {
        let onCancel: @Sendable () -> Void
        func cancel() { onCancel() }
    }
}

/// FSEvents based recursive watcher (real implementation, not covered by unit tests).
public struct FSEventsFolderWatcher: FolderWatching {
    public var latency: TimeInterval
    public init(latency: TimeInterval = 1.0) { self.latency = latency }

    public func watch(_ url: URL, onChange: @escaping @Sendable () -> Void) -> any FolderWatchToken {
        let box = FSEventsBox(path: url.path, latency: latency, onChange: onChange)
        return box
    }
}

private final class FSEventsBox: FolderWatchToken, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SSLibrary.fsevents")
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let lock = NSLock()

    init(path: String, latency: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSEventsBox>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let s = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    deinit { cancel() }
}
