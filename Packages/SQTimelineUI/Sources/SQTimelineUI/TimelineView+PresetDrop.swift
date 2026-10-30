import AppKit
import Foundation

extension NSPasteboard.PasteboardType {
    /// A Library preset dragged out (its UUID string).
    /// A Library title block dragged out (its preset UUID string); dropping places it at the drop time on free tracks above.
    public static let sequenceTitleBlock = NSPasteboard.PasteboardType("com.sequencestudio.title-block-id")
    public static let sequencePresetID = NSPasteboard.PasteboardType("com.sequencestudio.preset-id")
}


extension TimelineView {
    /// The preset drag on `pb` as an effect drop id, nil for anything else.
    static func presetEffectID(from pb: NSPasteboard) -> String? {
        pb.string(forType: .sequencePresetID).flatMap(UUID.init(uuidString:)).map(PresetDrop.effectID(for:))
    }
}
