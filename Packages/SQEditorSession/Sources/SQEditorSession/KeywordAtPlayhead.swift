import Foundation
import SQCore
import SQText

/// N5: the transcript word under the playhead becomes a big styled text clip (the "keyword" overlay of short videos).
/// Pure lookup and sizing rules; `EditorSession.addKeywordAtPlayhead()` does the edit. Uses only the caption tracks
/// (the transcript lives there as timed words), so the project file is untouched.
public enum KeywordAtPlayhead {
    /// Name of the text clip and template.
    public static let name = "Keyword"
    /// The clip runs this long past the next cut, so the word does not vanish exactly on the edit.
    static let pastCut = Time(3, 10)
    static let fallbackDuration = Time(1, 1)
    static let maxDuration = Time(3, 1)

    /// The word spoken at `t` on the visible caption tracks (timeline time). In a pause between two words of one
    /// caption the word spoken last counts; nil outside any caption or before its first word.
    public static func word(at t: Time, in timeline: Timeline) -> CaptionWord? {
        found(at: t, in: timeline)?.word
    }

    public struct Hit { var word: CaptionWord; var item: CaptionItem; var track: CaptionTrack }

    public static func found(at t: Time, in timeline: Timeline) -> Hit? {
        for track in timeline.captionTracks where track.isVisible {
            guard let item = track.items.first(where: { $0.range.contains(t) }) else { continue }
            let words = item.effectiveWords
            guard let w = words.last(where: { $0.range.start <= t }) else { continue }
            return Hit(word: w, item: item, track: track)
        }
        return nil
    }

    /// The word without punctuation at its edges ("Wow!", quotes, commas); inner marks stay (don't, 3.5).
    public static func cleaned(_ word: String) -> String {
        // Symbols ($ + ...) are never stripped; of the punctuation, the marks that carry meaning on their own stay: 100%, &, #1, @name.
        let edge = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "%&#@‰")).union(.whitespacesAndNewlines)
        return word.trimmingCharacters(in: edge)
    }

    /// Edit points of the cut footage only: clip edges of clips that are not generators (text, shapes, earlier keywords).
    public static func cutPoints(in t: Timeline) -> [Time] {
        var set = Set<Time>()
        for track in t.tracks { for c in track.clips where c.generator == nil { set.insert(c.start); set.insert(c.timeline.end) } }
        return set.sorted()
    }

    /// From the word start to the next cut plus 0.3 s (one second without a cut), never longer than 3 s and never
    /// shorter than the word itself.
    public static func range(for word: CaptionWord, editPoints: [Time], frameDuration: Time) -> TimeRange {
        let start = word.range.start.snapped(to: frameDuration)
        var end = editPoints.first(where: { $0 > word.range.start }).map { $0 + pastCut } ?? word.range.start + fallbackDuration
        end = min(end, word.range.start + maxDuration)
        end = max(end, word.range.end, word.range.start + pastCut)
        end = max(end.snapped(to: frameDuration), start + frameDuration)
        return TimeRange(start: start, end: end)
    }

    /// The caption look of the word's caption (track style, or the caption's own), made big: 8% of the frame height at
    /// least, heavy weight, a shadow, and the caption pop as animation.
    public static func template(text: String, format: SequenceFormat, item: CaptionItem, track: CaptionTrack) -> TextTemplate {
        let ref = item.styleOverridden || track.styleRef.isEmpty ? item.styleRef : track.styleRef
        var style = CaptionPresetLibrary.builtIn.style(for: ref.isEmpty ? nil : ref)
        style.size = max(style.size * 1.5, Double(format.height) * 0.08)
        style.weight = max(style.weight, .heavy)
        if style.shadow == nil {
            style.shadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6), angle: 135, distance: 4, blur: 10)
        }
        return TextTemplate(name: name, text: text, style: style, animation: .captionPop)
    }
}
