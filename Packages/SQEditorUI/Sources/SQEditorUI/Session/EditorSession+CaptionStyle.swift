import Foundation
import SQCore

/// Caption style of the track, per-caption overrides and the karaoke word highlight. One undo step per call.
extension EditorSession {
    /// The karaoke style of the first caption track that has one (nil: off everywhere).
    public var captionKaraoke: KaraokeStyle? { activeTimeline?.captionTracks.lazy.compactMap(\.karaoke).first }

    /// Turns the word highlight on (a style) or off (nil) for every caption track.
    @discardableResult
    public func setCaptionKaraoke(_ karaoke: KaraokeStyle?) -> Bool {
        guard let tl = activeTimeline, !tl.captionTracks.isEmpty else { return false }
        let ids = tl.captionTracks.map(\.id)
        return attempt(karaoke == nil ? "Word Highlight Off" : "Word Highlight") { t in
            for id in ids { try t.setCaptionKaraoke(karaoke, track: id) }
        }
    }

    /// The selected captions get their own style (the track style no longer changes them); nil hands them back.
    @discardableResult
    public func setSelectedCaptionStyle(_ styleRef: String?) -> Bool {
        guard !captionSelection.isEmpty else { return false }
        let ids = captionSelection
        return attempt(styleRef == nil ? "Use Track Style" : "Caption Style") { try $0.setCaptionItemStyle(ids, styleRef: styleRef) }
    }

    /// True when any selected caption has a style of its own.
    public var selectedCaptionsHaveOwnStyle: Bool {
        let ids = captionSelection
        return captionItems.contains { ids.contains($0.id) && $0.styleOverridden }
    }
}
