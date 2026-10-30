#if canImport(CoreText)
import Foundation
import SQCore
import Synchronization

extension TextGenerator {
    /// A text layer's box in a graphic (offset from the canvas center, y down, layer Motion not applied): the raster of
    /// `frame` at scale 1, with its animation offset. One definition for the Graphics overlay (`GraphicsEditor.textMeasure`)
    /// and Follow at evaluation time, so both see the same box. nil for empty or undecodable text. Lays the text out on the
    /// calling thread when it is not cached.
    public static func graphicsRect(ref: GeneratorRef, localTime: Time, clipDuration: Time, canvas: SequenceFormat) -> GraphicsRect? {
        guard let f = try? frame(ref: ref, localTime: localTime, clipDuration: clipDuration, canvas: canvas, scale: 1) else {
            return nil
        }
        let minX = f.x - Double(canvas.displayWidth) / 2 + f.offsetX, minY = f.y - Double(canvas.height) / 2 + f.offsetY
        return GraphicsRect(minX: minX, minY: minY, maxX: minX + f.width, maxY: minY + f.height)
    }

    /// G11: lets SQCore's evaluation measure text targets of Follow. Idempotent; the playback loop, the exporter and the
    /// Graphics editor call it before they evaluate.
    ///
    /// Outside an exact evaluation (export) a text that is not laid out yet is never laid out on the caller (the render
    /// thread): the layer's last measured text stands in when it is still cached (typing keeps the box on the old text, as
    /// the picture keeps the old raster), otherwise nil (the follower draws as authored); the text is laid out on a
    /// background task and `followMeasureObservers` are told, so playback redraws.
    public static func installFollowMeasure() {
        followMeasure.withLock { st in
            guard !st.installed else { return }
            st.installed = true
            GraphicsTextBounds.install { ref, clip, layer, t, dur, canvas, exact in
                followRect(ref: ref, clip: clip, layer: layer, localTime: t, clipDuration: dur, canvas: canvas, exact: exact)
            }
        }
    }

    /// Calls `body` (any thread) with the text when a text that Follow asked for is laid out in the background (the
    /// observer decides whether it shows that text). Replaces `owner`'s previous observer; `removeFollowMeasureObserver`
    /// on deinit.
    public static func addFollowMeasureObserver(_ owner: AnyObject, _ body: @escaping @Sendable (GeneratorRef) -> Void) {
        followMeasure.withLock { $0.observers[ObjectIdentifier(owner)] = body }
    }

    public static func removeFollowMeasureObserver(_ owner: AnyObject) {
        followMeasure.withLock { _ = $0.observers.removeValue(forKey: ObjectIdentifier(owner)) }
    }

    /// Texts laid out for Follow on the calling thread since launch (tests: never outside an exact evaluation).
    static var followSyncLayouts: Int { followMeasure.withLock { $0.syncLayouts } }

    /// The stand-in table key: layers of clips made from one template share ids, so the clip is part of it.
    struct FollowKey: Hashable { let clip: UUID; let layer: UUID }

    static func followRect(ref: GeneratorRef, clip: UUID, layer: UUID, localTime t: Time, clipDuration dur: Time,
                           canvas: SequenceFormat, exact: Bool) -> GraphicsRect? {
        let key = FollowKey(clip: clip, layer: layer)
        if isCached(ref: ref) || exact {
            let cold = !isCached(ref: ref)
            let r = graphicsRect(ref: ref, localTime: t, clipDuration: dur, canvas: canvas)
            followMeasure.withLock { st in
                if cold { st.syncLayouts += 1 }
                if r != nil, st.lastRef[key] != ref {
                    if st.lastRef.count >= followStandInLimit { st.lastRef.removeAll(keepingCapacity: true) }
                    st.lastRef[key] = ref
                }
            }
            return r
        }
        let standIn = followMeasure.withLock { $0.lastRef[key] }
        // The in-flight table is shared with the playback loop's prewarm; the observers are told once it is laid out.
        warmInBackground(ref) {
            let observers = followMeasure.withLock { Array($0.observers.values) }
            for o in observers { o(ref) }
        }
        guard let standIn, standIn != ref, isCached(ref: standIn) else { return nil }
        return graphicsRect(ref: standIn, localTime: t, clipDuration: dur, canvas: canvas)
    }
}

private struct FollowMeasureState {
    var installed = false
    /// Last text measured per text layer of a clip (stand-in while its new text is laid out).
    var lastRef: [TextGenerator.FollowKey: GeneratorRef] = [:]
    var observers: [ObjectIdentifier: @Sendable (GeneratorRef) -> Void] = [:]
    var syncLayouts = 0
}

private let followMeasure = Mutex(FollowMeasureState())
private let followStandInLimit = 4096
#endif
