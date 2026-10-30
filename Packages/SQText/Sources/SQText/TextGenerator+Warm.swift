#if canImport(CoreText)
import Foundation
import Synchronization

extension TextGenerator {
    /// Lays a text out on a background task, once per ref however many callers ask (the playback loop's prewarm and
    /// Follow's measure share this table, so one text is never laid out twice at the same time). `done` runs on that task
    /// when the layout finished or failed; callers that ask while it is in flight are told too. Does nothing (and never
    /// calls `done`) for a cached text or one whose layout failed (until `resetFailedLayouts`).
    public static func warmInBackground(_ ref: GeneratorRef, done: (@Sendable () -> Void)? = nil) {
        if isCached(ref: ref) { return }
        let start: Bool? = warmTable.withLock { st in
            if st.failed.contains(ref) { return nil }
            if st.pending[ref] != nil {
                if let done { st.pending[ref]?.append(done) }
                return false
            }
            st.pending[ref] = done.map { [$0] } ?? []
            return true
        }
        guard start == true else { return }
        let tally = rasterTally     // the asker's (tests wait for their own layouts with it)
        tally?.began()
        Task.detached(priority: .userInitiated) {
            defer { tally?.ended() }
            let ok = (try? prewarm(ref: ref)) != nil
            let waiting = warmTable.withLock { st -> [@Sendable () -> Void] in
                if !ok { markFailedLocked(&st, ref) }
                return st.pending.removeValue(forKey: ref) ?? []
            }
            for w in waiting { w() }
        }
    }

    /// The layout of `ref` failed (reported once, never retried while the failure stands).
    public static func layoutFailed(_ ref: GeneratorRef) -> Bool { warmTable.withLock { $0.failed.contains(ref) } }

    /// Remembers a failed layout (a raster that threw on the caller's thread).
    public static func markLayoutFailed(_ ref: GeneratorRef) { warmTable.withLock { markFailedLocked(&$0, ref) } }

    /// Forgets failed layouts so they are tried again: call when fonts were registered (a missing font may exist now).
    /// `clearCache` does it too.
    /// Observers (the playback loops) are told when failed layouts were forgotten, so a paused monitor redraws them.
    public static func resetFailedLayouts() {
        FontResolver.fontsChanged()
        let observers = warmTable.withLock { st -> [@Sendable () -> Void] in
            let had = !st.failed.isEmpty
            st.failed.removeAll()
            return had ? Array(st.resetObservers.values) : []
        }
        for o in observers { o() }
    }

    /// Calls `body` (any thread) when `resetFailedLayouts` forgot at least one failure. Replaces `owner`'s observer.
    public static func addFailedLayoutResetObserver(_ owner: AnyObject, _ body: @escaping @Sendable () -> Void) {
        warmTable.withLock { $0.resetObservers[ObjectIdentifier(owner)] = body }
    }

    public static func removeFailedLayoutResetObserver(_ owner: AnyObject) {
        warmTable.withLock { _ = $0.resetObservers.removeValue(forKey: ObjectIdentifier(owner)) }
    }

    /// Texts being laid out in the background right now (tests).
    static var warmInFlight: Int { warmTable.withLock { $0.pending.count } }

    private static func markFailedLocked(_ st: inout WarmState, _ ref: GeneratorRef) {
        if st.failed.count >= 4096 { st.failed.removeAll(keepingCapacity: true) }
        st.failed.insert(ref)
    }
}

private struct WarmState {
    var pending: [GeneratorRef: [@Sendable () -> Void]] = [:]
    var failed: Set<GeneratorRef> = []
    var resetObservers: [ObjectIdentifier: @Sendable () -> Void] = [:]
}

private let warmTable = Mutex(WarmState())
#endif
