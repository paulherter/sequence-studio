import Foundation
import SQCore
import SQText

extension EditorSession {
    /// Turns the transcript word under the playhead into a big text clip on the topmost free video track (a new one on top when none is free; never overwrites), from the word
    /// start to the next cut (see `KeywordAtPlayhead.range`). One undo step; the new clip is selected.
    @discardableResult
    public func addKeywordAtPlayhead() -> Bool {
        guard let t = activeTimeline else { return false }
        guard let hit = KeywordAtPlayhead.found(at: playhead, in: t) else {
            setError("No transcript word under the playhead. Create captions first."); return false
        }
        let text = KeywordAtPlayhead.cleaned(hit.word.text)
        guard !text.isEmpty else { setError("The word under the playhead is only punctuation."); return false }
        let range = KeywordAtPlayhead.range(for: hit.word, editPoints: KeywordAtPlayhead.cutPoints(in: t), frameDuration: t.frameDuration)
        let template = KeywordAtPlayhead.template(text: text, format: t.format, item: hit.item, track: hit.track)
        return addTextClip(template: template, at: range.start, duration: range.duration, neverOverwrite: true) != nil
    }
}
