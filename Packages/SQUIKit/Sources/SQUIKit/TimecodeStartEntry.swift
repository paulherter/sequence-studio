import Foundation
import SQCore

/// State of the "Starts at" field in Sequence Settings. The start is kept as a rational `Time`, never as text, so a change of
/// frame rate or of Display (Timecode / Frames) reformats the text instead of reinterpreting it: "1800" typed as frames stays
/// 1800 frames when Display switches to Timecode (then reads "00:01:00:00" at 30 fps).
public struct TimecodeStartEntry: Sendable, Equatable {
    /// Last valid start (never negative).
    public private(set) var start: Time
    public private(set) var frameDuration: Time
    public private(set) var framesOnly: Bool
    /// Field text as shown; may be invalid while the user is typing.
    public private(set) var text: String
    /// False when `text` does not parse. `start` still holds the last valid value, so nothing is lost.
    public private(set) var isValid = true

    public init(start: Time, frameDuration: Time, framesOnly: Bool) {
        self.start = start
        self.frameDuration = frameDuration
        self.framesOnly = framesOnly
        text = ""
        text = timecode.format(start)
    }

    /// Drop frame where the rate has it; frame counts when `framesOnly`.
    public var timecode: Timecode {
        var tc = Timecode(frameDuration: frameDuration, dropFrame: true)
        tc.framesOnly = framesOnly
        return tc
    }

    /// The user edited the field. A valid, non-negative entry becomes the start; otherwise the entry is flagged invalid.
    public mutating func setText(_ newText: String) {
        text = newText
        if let t = timecode.parse(newText), t >= .zero {
            start = t
            isValid = true
        } else {
            isValid = false
        }
    }

    /// Frame rate and / or Display changed: the start stays the same time, the text is formatted again. Call `setText` with the
    /// field's current text first so a pending edit is not dropped.
    public mutating func reconfigure(frameDuration newDuration: Time, framesOnly newFramesOnly: Bool) {
        frameDuration = newDuration
        framesOnly = newFramesOnly
        text = timecode.format(start)
        isValid = true
    }
}
