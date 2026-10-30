import Foundation
import SQCore

/// Feeds a slow, point-prompted segmenter from a fast pointer (Magic hover on Windows, where one answer takes
/// 50-150 ms): moves are debounced, one answer runs at a time, and a result that arrives after newer moves is still
/// shown (the next one replaces it), so a pointer that keeps moving still gets a highlight. `clear` drops the answer and
/// anything in flight. The Mac segmenter knows every object of a frame at once and needs none of this.
@MainActor
public final class HoverFeeder<Answer: Sendable> {
    /// The latest answer and the frame (source seconds) it belongs to.
    public private(set) var answer: (value: Answer, seconds: Double)?
    /// An answer arrived or was dropped: the host redraws.
    public var onChange: (() -> Void)?
    public var isPending: Bool { pending != nil || working }

    private let delay: Duration
    private let segment: @Sendable (Vec2, Double) async -> Answer?
    private var pending: (point: Vec2, seconds: Double)?
    private var working = false
    private var epoch = 0

    public init(delay: Duration = .milliseconds(90), segment: @escaping @Sendable (Vec2, Double) async -> Answer?) {
        self.delay = delay
        self.segment = segment
    }

    /// The pointer rests at `point` on the frame at `seconds`.
    public func move(_ point: Vec2, seconds: Double) {
        pending = (point, seconds)
        guard !working else { return }
        working = true
        Task { @MainActor [weak self] in await self?.drain() }
    }

    /// The pointer left the picture, the frame or tool changed: nothing is shown or waits.
    public func clear() {
        epoch += 1
        pending = nil
        if answer != nil { answer = nil; onChange?() }
    }

    private func drain() async {
        defer { working = false }
        while pending != nil {
            try? await Task.sleep(for: delay)
            guard let want = pending else { return }
            pending = nil
            let mine = epoch
            let value = await segment(want.point, want.seconds)
            guard mine == epoch else { continue }      // cleared meanwhile
            if let value { answer = (value, want.seconds) } else if answer != nil { answer = nil } else { continue }
            onChange?()
        }
    }
}
