import Foundation
import SQCore
import SQText

/// Caption rasters drawn ahead of the clock while playing. A text animator (word pop, highlight) needs a new raster per
/// in-between frame, 10 to 25 ms of CPU each: drawn on the render thread every frame it held the monitor under the
/// frame rate. The lane draws the next frames on worker threads; the render thread takes a finished raster, or the last
/// one of the same text (right words, animation a few frames old) when it is not ready, and never waits.
/// A paused monitor, Export Frame and the export draw synchronously (`WinCompositor.asyncCaptions` is off).
final class WinCaptionLane: @unchecked Sendable {
    private struct Key: Hashable { let ref: GeneratorRef; let ms: Int }
    private enum Slot { case frame(PortableTextFrame), empty }

    private let lock = NSLock()
    private var done: [Key: Slot] = [:]
    private var order: [Key] = []
    private var pending: Set<Key> = []
    private var latest: [GeneratorRef: PortableTextFrame] = [:]
    private var canvas: (Int, Int)?
    private let queue = DispatchQueue(label: "sq.caption-lane", qos: .userInitiated, attributes: .concurrent)
    /// Rasters kept (an animated one is a few MB of floats).
    private static let limit = 96

    private static func ms(_ t: Time) -> Int { Int((Double(t.value) / Double(max(1, t.timescale)) * 1000).rounded()) }

    /// The raster to draw for `ref` at `localTime`: nil for empty text or while nothing of this text is drawn yet.
    /// Queues this frame and `ahead` more, one `step` apart.
    func frame(ref: GeneratorRef, localTime: Time, duration: Time, step: Time, ahead: Int, canvas format: SequenceFormat) -> PortableTextFrame? {
        lock.lock()
        let size = (format.width, format.height)
        if let c = canvas, c != size { done = [:]; order = []; latest = [:]; pending = [] }
        canvas = size
        let slot = done[Key(ref: ref, ms: Self.ms(localTime))]
        let fallback = latest[ref]
        lock.unlock()
        for i in 0...ahead {
            let t = i == 0 ? localTime : localTime + step * Int64(i)
            if t > duration { break }
            enqueue(ref, t, duration, format)
        }
        switch slot {
        case .frame(let f)?: return f
        case .empty?: return nil
        case nil: return fallback
        }
    }

    /// Queues `count` frames from `localTime` (the caption that follows the playhead by a moment).
    func prepare(ref: GeneratorRef, localTime: Time, duration: Time, step: Time, count: Int, canvas format: SequenceFormat) {
        for i in 0..<count where localTime + step * Int64(i) <= duration { enqueue(ref, localTime + step * Int64(i), duration, format) }
    }

    private func enqueue(_ ref: GeneratorRef, _ t: Time, _ duration: Time, _ format: SequenceFormat) {
        let key = Key(ref: ref, ms: Self.ms(t))
        lock.lock()
        if done[key] != nil || pending.contains(key) { lock.unlock(); return }
        pending.insert(key)
        let previous = latest[ref]
        lock.unlock()
        queue.async { [self] in
            let frame = try? TextGenerator.portableFrame(ref: ref, localTime: t, clipDuration: duration, canvas: format, raster: previous)
            lock.lock()
            pending.remove(key)
            done[key] = frame.map { .frame($0) } ?? .empty
            order.append(key)
            if let frame { latest[ref] = frame }
            while order.count > Self.limit { done[order.removeFirst()] = nil }
            lock.unlock()
        }
    }
}
