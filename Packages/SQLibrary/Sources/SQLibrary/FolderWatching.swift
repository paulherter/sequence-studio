import Foundation

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
