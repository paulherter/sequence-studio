import Foundation
import Observation
import SQCore

/// Trim mode state (TL-08 / TL-09): the edit point being trimmed and which side the buttons and keys change. While it is on,
/// the Program monitor shows the two-up view. No project data: nothing here is saved.
@MainActor @Observable
public final class TrimModeModel {
    /// The frame steps of the two-up monitor's buttons, left to right.
    public static let steps = [-5, -1, 1, 5]

    public private(set) var point: TrimPoint?
    public private(set) var side: TrimSide = .roll
    /// Last result line under the buttons ("Rolled +2 frames", or why nothing moved); empty when there is none.
    public private(set) var note = ""
    public var isActive: Bool { point != nil }

    private unowned let session: EditorSession
    /// Called after every change of point, side or timeline, so the view re-seeks its two monitors.
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(session: EditorSession) { self.session = session }

    /// Starts Trim mode on `point` with `side` (nil = the side next to the pointer, never a roll).
    public func enter(_ p: TrimPoint, side s: TrimSide? = nil, pointerBefore: Bool = false) {
        point = p
        side = s ?? p.defaultSide(pointerBefore: pointerBefore)
        note = ""; dynamicDirection = 0; dynamicLevel = 0
        onChange?()
    }

    /// The edit nearest to the playhead on the targeted tracks; false when the sequence has no edit.
    @discardableResult
    public func enterNearestPlayhead() -> Bool {
        guard let t = activeTimeline, let p = t.nearestTrimPoint(to: session.playhead) else { return false }
        enter(p, side: p.supports(.roll) ? .roll : nil)
        return true
    }

    public func exit() {
        guard point != nil else { return }
        point = nil; note = ""
        onChange?()
    }

    /// Ctrl+T while Trim mode is on: outgoing, incoming, roll.
    public func cycleSide() {
        guard let p = point else { return }
        side = side.next(in: p)
        note = ""; dynamicDirection = 0; dynamicLevel = 0
        onChange?()
    }

    public func select(_ s: TrimSide) {
        guard let p = point, p.supports(s) else { return }
        side = s; note = ""
        onChange?()
    }

    /// The -5 -1 +1 +5 buttons and Left / Right: one undo step per press. False when Trim mode is off.
    @discardableResult
    public func step(frames n: Int) -> Bool {
        guard let p = point else { return false }
        guard let moved = session.trimEdit(p, side: side, frames: n) else {
            note = session.lastError ?? "Cannot trim here."
            onChange?()
            return true
        }
        if moved == .zero {
            note = "No more footage that way."
        } else if let t = activeTimeline {
            let frames = Int(moved.frameIndex(frameDuration: t.frameDuration))
            note = "\(side == .roll ? "Moved edit" : "Trimmed") \(frames > 0 ? "+" : "")\(frames) frame\(abs(frames) == 1 ? "" : "s")"
        }
        refresh()
        return true
    }

    /// Frames per press of J / L: a repeated press in the same direction (or the key held) speeds up to the last entry.
    public static let dynamicSteps = [1, 2, 5, 10]
    private var dynamicDirection = 0
    private var dynamicLevel = 0

    /// J / K / L in Trim mode (dynamic trim): J trims back, L trims forward, each press one undo step; pressing the same
    /// key again goes faster (1, 2, 5, 10 frames), the other direction restarts slow, K stops. False when Trim mode is off.
    @discardableResult
    public func dynamicTrim(_ key: ShuttleKey) -> Bool {
        guard point != nil else { return false }
        switch key {
        case .k:
            dynamicDirection = 0; dynamicLevel = 0
            note = "Dynamic trim stopped"
            onChange?()
            return true
        case .j, .l:
            let dir = key == .l ? 1 : -1
            if dir == dynamicDirection { dynamicLevel = min(dynamicLevel + 1, Self.dynamicSteps.count - 1) }
            else { dynamicDirection = dir; dynamicLevel = 0 }
            return step(frames: dir * Self.dynamicSteps[dynamicLevel])
        }
    }

    /// The timeline changed (undo, redo, an edit elsewhere): re-read the point, leave Trim mode when its clips are gone.
    public func refresh() {
        guard let p = point else { return }
        guard let t = activeTimeline, let r = t.resolved(p) else { exit(); return }
        point = r
        if !r.supports(side) { side = r.defaultSide(pointerBefore: false) }
        onChange?()
    }

    /// Frame times of the two monitors (last outgoing frame, first incoming frame).
    public var frames: (outgoing: Time?, incoming: Time?) {
        guard let p = point, let t = activeTimeline else { return (nil, nil) }
        return t.trimFrames(p)
    }

    private var activeTimeline: Timeline? { session.activeTimeline }
}
