import Foundation

// v58: animation zones (`Clip.zones`, AnimationZones.swift) and applied title templates (`Clip.templateSlots`,
// TitleTemplate.swift). A v57 build would drop the zones (a trim then moves the intro/outro keys like any key, and a
// template clip plays its inner sequence through the source range) and the slots, then lose both on the next save; at v58
// it refuses the file with `ProjectFileError.newerVersion` instead.

extension Project {
    /// Any clip carries animation zones or template slots: the file must be v58.
    public var containsV58Content: Bool {
        timelines.contains { t in t.tracks.contains { $0.clips.contains { $0.zones != nil || $0.templateSlots != nil } } }
    }
}
