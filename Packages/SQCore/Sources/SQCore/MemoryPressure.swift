import Dispatch
import Foundation
import Synchronization

/// System memory-pressure level (`DispatchSource` memory-pressure events).
public enum MemoryPressure: Int, Sendable, Equatable, Comparable {
    case normal, warning, critical

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The part of a cache's full budget kept at this level: normal all, warning 1/2, critical 1/4. One rule for every
    /// cache (frame cache, posters, thumbnails, waveforms), so they shrink together.
    public func budget(_ full: Int) -> Int {
        switch self {
        case .normal: full
        case .warning: full / 2
        case .critical: full / 4
        }
    }
}

/// Delivers memory-pressure levels to one cache (injectable: tests and the bench fire events by hand). `start` is called
/// once by the owner; the handler may run on any thread. `cancel` stops delivery for good.
public protocol MemoryPressureSource: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable (MemoryPressure) -> Void)
    func cancel()
}

/// Keeps one registration alive; dropping or canceling it stops delivery.
public final class MemoryPressureToken: Sendable {
    private let onCancel = CallbackSlot()
    init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel.set(onCancel) }
    public func cancel() { onCancel.take()?() }
    deinit { cancel() }
}

/// The one place every memory-hungry cache listens to memory pressure (memory audit 2026-10-04). Before, the frame
/// caches and the render loop each opened their own `DispatchSource`, and the poster, thumbnail and waveform caches
/// had none. `shared` owns a single system source (started on first registration); `post` lets tests, the bench and the
/// app fire a level by hand. A registration made while the level is not normal gets that level at once, so a cache
/// created under pressure starts small. Handlers run outside the lock, on a posting thread (the system source's
/// private queue): owners hop to their own actor if they need one. Each registration sees levels in post order, one
/// call at a time: a level older than one already delivered is dropped (a racing `post(.normal)` is never followed by
/// a stale warning), and a post arriving while its handler runs is delivered right after by the thread running it.
public final class MemoryPressureRegistry: Sendable {
    public static let shared = MemoryPressureRegistry(systemEvents: true)

    /// In-order delivery to one registration: `deliver` records the level if it is newer than any seen; whichever
    /// thread is not already delivering runs the handler (outside the lock) until the newest level is delivered.
    private final class Gate: Sendable {
        private struct S { var pending: MemoryPressure?; var seen = 0; var delivering = false }
        private let s = Mutex(S())
        let handler: @Sendable (MemoryPressure) -> Void
        init(_ handler: @escaping @Sendable (MemoryPressure) -> Void) { self.handler = handler }

        func deliver(_ level: MemoryPressure, seq: Int) {
            let run = s.withLock { s -> Bool in
                guard seq > s.seen else { return false }        // stale: a newer level was already seen
                s.seen = seq; s.pending = level
                guard !s.delivering else { return false }        // the thread delivering picks it up
                s.delivering = true
                return true
            }
            guard run else { return }
            while let next = s.withLock({ s -> MemoryPressure? in
                guard let p = s.pending else { s.delivering = false; return nil }
                s.pending = nil
                return p
            }) { handler(next) }
        }
    }

    private struct Entry: Sendable { let name: String; let gate: Gate }
    private struct State: Sendable {
        var level: MemoryPressure = .normal
        /// Sequence number of the last post (orders deliveries; a registration starts at the one current then).
        var seq = 0
        var next = 0
        var entries: [Int: Entry] = [:]
        var posts = 0
    }
    /// Dispatch sources are thread-safe but not annotated Sendable.
    #if canImport(Darwin)
    private struct SourceBox: @unchecked Sendable { let source: any DispatchSourceMemoryPressure }
    #else
    private struct SourceBox: @unchecked Sendable { let source: SourceStub }
    /// Linux has no memory-pressure dispatch source: a no-op stand-in.
    private struct SourceStub { func cancel() {} }
    #endif

    private let state = Mutex(State())
    private let systemEvents: Bool
    private let source = Mutex<SourceBox?>(nil)
    private let queue = DispatchQueue(label: "SQCore.memoryPressure", qos: .utility)

    /// `systemEvents`: listen to the system's memory-pressure notifications (only `shared`; tests post by hand).
    public init(systemEvents: Bool = false) { self.systemEvents = systemEvents }

    deinit { source.withLock { $0 }?.source.cancel() }

    public var level: MemoryPressure { state.withLock { $0.level } }
    /// Levels posted so far (diagnostics).
    public var postCount: Int { state.withLock { $0.posts } }
    /// Names of the live registrations (diagnostics, the bench).
    public var registeredNames: [String] { state.withLock { $0.entries.values.map(\.name) } }

    /// Registers `handler` under `name` until the returned token is dropped or canceled.
    public func register(_ name: String, _ handler: @escaping @Sendable (MemoryPressure) -> Void) -> MemoryPressureToken {
        register(name, handler, beforeInitialDelivery: nil)
    }

    /// `beforeInitialDelivery`: runs between reading the level and delivering it (tests: a post racing a registration).
    func register(_ name: String, _ handler: @escaping @Sendable (MemoryPressure) -> Void,
                  beforeInitialDelivery: (() -> Void)?) -> MemoryPressureToken {
        let gate = Gate(handler)
        let (id, now, seq) = state.withLock { s -> (Int, MemoryPressure, Int) in
            s.next += 1
            s.entries[s.next] = Entry(name: name, gate: gate)
            return (s.next, s.level, s.seq)
        }
        if systemEvents { startSystemSource() }
        beforeInitialDelivery?()
        // Same sequence number as the post that set `now`: any later post is newer and wins.
        if now != .normal { gate.deliver(now, seq: seq) }
        return MemoryPressureToken { [weak self] in _ = self?.state.withLock { $0.entries.removeValue(forKey: id) } }
    }

    /// Delivers `level` to every registration (also when it repeats: the system re-sends warnings while memory stays short).
    public func post(_ level: MemoryPressure) {
        let (gates, seq) = state.withLock { s -> ([Gate], Int) in
            s.level = level; s.posts += 1; s.seq += 1
            return (s.entries.sorted { $0.key < $1.key }.map(\.value.gate), s.seq)
        }
        for g in gates { g.deliver(level, seq: seq) }
    }

    private func startSystemSource() {
        #if canImport(Darwin)
        source.withLock { box in
            guard box == nil else { return }
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
            let b = SourceBox(source: src)
            src.setEventHandler { [weak self, b] in
                let e = b.source.data
                self?.post(e.contains(.critical) ? .critical : e.contains(.warning) ? .warning : .normal)
            }
            src.activate()
            box = b
        }
        #endif
    }
}

/// A `MemoryPressureSource` that listens through a `MemoryPressureRegistry` (the shared one by default, i.e. the
/// system's notifications). Kept as the injection point of `FrameCache`, `RenderLoop` and `MemoryPressureMonitor`.
public final class SystemMemoryPressureSource: MemoryPressureSource {
    private let registry: MemoryPressureRegistry
    private let name: String
    private let token = Mutex<MemoryPressureToken?>(nil)

    public init(registry: MemoryPressureRegistry = .shared, name: String = "cache") {
        self.registry = registry; self.name = name
    }

    public func start(_ handler: @escaping @Sendable (MemoryPressure) -> Void) {
        let t = registry.register(name, handler)
        token.withLock { old -> MemoryPressureToken? in let o = old; old = t; return o }?.cancel()
    }

    public func cancel() { token.withLock { t -> MemoryPressureToken? in let o = t; t = nil; return o }?.cancel() }
}
