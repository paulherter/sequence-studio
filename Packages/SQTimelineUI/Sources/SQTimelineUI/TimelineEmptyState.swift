import Foundation
import SQCore

/// The text and the rule of the timeline's empty state (INTERACTION-AUDIT §10). Pure, so it can be tested.
public enum TimelineEmptyState {
    /// True while nothing is on the timeline: no clip on any track and no caption.
    public static func isEmpty(_ timeline: Timeline) -> Bool {
        timeline.tracks.allSatisfy { $0.clips.isEmpty } && timeline.captionTracks.allSatisfy { $0.items.isEmpty }
    }

    public static let title = "Nothing on the timeline yet"

    /// "Drag clips here, or press , to insert the Source clip": the key comes from the key map.
    public static func hint(map: CommandMap = .current) -> String {
        guard let b = map.binding(for: .insert) else { return "Drag clips here from the Project panel" }
        return "Drag clips here, or press \(KeyboardListing.text(for: b)) to insert the Source clip"
    }

    /// Visible only for an empty timeline and no drop in flight (the drop ghost explains itself).
    public static func isVisible(timeline: Timeline, dropActive: Bool) -> Bool { !dropActive && isEmpty(timeline) }
}
