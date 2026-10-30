import Foundation
import SQCore
import SQDrawTimeline
import SQInspectorUI
import SQTimelineUI

/// The timeline key lane fed by Effect Controls, as the Mac host installs it (`setKeyLaneSection`,
/// `selectedKeyLaneTimes`, `onKeyLaneClick`): the selected section's keys from the portable `KeyLanes`, picked keys
/// from the model. Presses come back through `TimelineEditorRequest.keyLaneKey` (`AppController.openTimelineEditor`).
public final class InspectorKeyLanes: TimelineKeyLaneSource {
    private let model: EffectControlsModel

    public init(model: EffectControlsModel) { self.model = model }

    public func keyLane(clip: Clip, clipRect: CGRect, visible: CGRect, selected: Bool, geometry: TimelineGeometry) -> TimelineKeyLane? {
        let model = model     // the closure takes the (main-actor) model, not the non-Sendable source
        return MainActor.assumeIsolated {
            guard let k = KeyLanes.layout(clip: clip, section: model.selectedSection, clipRect: clipRect, visible: visible,
                                          selected: selected, picked: model.keyLaneSelectedTimes,
                                          frameDuration: geometry.frameDuration, x: { geometry.x(for: $0) }) else { return nil }
            return TimelineKeyLane(lane: k.lane, glyphs: k.glyphs.map { .init(center: $0.center, selected: $0.selected) },
                                   glyphSize: KeyLanes.glyphSize)
        }
    }

    public func keyLaneHit(clip: Clip, clipRect: CGRect, at p: CGPoint, geometry: TimelineGeometry) -> Time? {
        let model = model
        return MainActor.assumeIsolated {
            guard let section = model.selectedSection,
                  KeyLanes.isApplicable(clip: clip, section: section, selected: true, rowHeight: clipRect.height) else { return nil }
            return KeyLanes.hitTest(clip: clip, section: section, clipRect: clipRect, at: p,
                                    frameDuration: geometry.frameDuration, x: { geometry.x(for: $0) })
        }
    }
}
