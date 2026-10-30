import Foundation

// v62: `TemplateSlot.graphicsLayer` (TitleTemplate.swift): a template field addressing one text layer inside a graphics clip.
// A v61 build would drop the field on decode, then write the slot into the clip's own (empty) generator payload and lose it
// on the next save; at v62 it refuses the file with `ProjectFileError.newerVersion` instead.

extension Project {
    /// Any applied template clip has a slot that addresses a graphics layer: the file must be v62.
    public var containsV62Content: Bool {
        allClips().contains { $0.templateSlots?.contains { $0.graphicsLayer != nil } ?? false }
    }
}
