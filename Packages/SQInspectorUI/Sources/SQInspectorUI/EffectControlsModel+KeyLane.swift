import Foundation
import SQCore

extension EffectControlsModel {
    /// A press on a diamond of the timeline key lane: selects every key of the shown section at that timeline time
    /// (Shift toggles it into the selection). False when the time holds no key or the lane clip is not the shown clip.
    @discardableResult
    public func selectKeyLaneKey(clip id: Clip.ID, at time: Time, extend: Bool) -> Bool {
        guard let c = clip, c.id == id, let section = selectedSection,
              let key = summaryKeys(section).first(where: { c.start + $0.time == time }) else { return false }
        selectSummary(key, extend: extend)
        return true
    }

    /// Timeline times of the lane keys that are fully selected (the timeline draws them filled).
    public var keyLaneSelectedTimes: Set<Time> {
        guard let c = clip, let section = selectedSection, !selection.isEmpty else { return [] }
        return Set(summaryKeys(section).filter { isSelected($0) }.map { c.start + $0.time })
    }
}
