import Foundation
import SQCore
import SQUIKit

/// Parsing of the numbers typed in the Scale Time and Keyframe Velocity dialogs.
public enum KeyToolsInput {
    /// "50", "50 %" or "12,5" as a ratio num/den (percent in thousandths); nil unless > 0 and <= 10000 percent.
    public static func timeScaleRatio(_ text: String) -> (num: Int64, den: Int64)? {
        guard let v = number(text), v > 0, v <= 10_000 else { return nil }
        return (Int64((v * 1000).rounded()), 100_000)
    }

    /// A whole number inside `range`, else nil.
    public static func wholeNumber(_ text: String, in range: ClosedRange<Int>) -> Int? {
        guard let v = number(text), v == v.rounded(), v >= Double(range.lowerBound), v <= Double(range.upperBound) else { return nil }
        return Int(v)
    }

    /// The three Wiggle fields: frequency 1...60 per second, amount > 0, seed a whole number >= 0.
    public static func wiggle(frequency: String, amount: String, seed: String) -> (perSecond: Int, amount: Double, seed: UInt64)? {
        guard let f = wholeNumber(frequency, in: 1...60), let a = number(amount), a > 0,
              let s = wholeNumber(seed, in: 0...Int(Int32.max)) else { return nil }
        return (f, a, UInt64(s))
    }

    /// A plain number (comma or point) with an optional trailing "%" or unit text; nil when no number leads.
    public static func number(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(t.prefix { "0123456789.-".contains($0) })
    }
}

/// A key tool's dialog as data (title, note, fields, confirm button): the Mac `KeyToolsDialogs` and the shared-toolkit
/// hosts show the same questions and read the answers through the same parsers.
public struct KeyToolPrompt: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var label: String
        public var text: String
    }
    public var title: String
    public var informative: String
    public var confirm: String
    public var fields: [Field]

    public static let scaleTime = KeyToolPrompt(title: "Scale Time", informative: "Scales the distance of the selected keys to the earliest one.",
                                                confirm: "Scale", fields: [Field(label: "Scale", text: "100 %")])
    public static let loop = KeyToolPrompt(title: "Loop", informative: "Repeats the key pattern after its last key.", confirm: "Loop",
                                           fields: [Field(label: "Repeats", text: "1")])
    public static let wiggle = KeyToolPrompt(title: "Wiggle", informative: "Adds random offsets between the first and last selected key.",
                                             confirm: "Wiggle", fields: [Field(label: "Frequency (/s)", text: "5"), Field(label: "Amount", text: "0.1"),
                                                                         Field(label: "Seed", text: "1")])
    public static let saveCurve = KeyToolPrompt(title: "Save Curve", informative: "Name for the new easing preset.", confirm: "Save",
                                                fields: [Field(label: "Name", text: "Curve")])

    /// A name for a Look or a saved animation (TextBlockView.promptLookName): one field, OK / Cancel.
    public static func name(_ title: String, initial: String) -> KeyToolPrompt {
        KeyToolPrompt(title: title, informative: "", confirm: "OK", fields: [Field(label: "Name", text: initial)])
    }

    /// R29: turning a parameter's animation off asks before its keys go (no fields; confirm = remove).
    public static func removeKeyframes(_ title: String) -> KeyToolPrompt {
        KeyToolPrompt(title: SQL10n.format("Remove all %@ keyframes?", SQL10n.string(title)),
                      informative: "The property keeps the value it has at the playhead.", confirm: "Remove", fields: [])
    }

    /// Keyframe Velocity: speed (display units per second) and influence (percent) per side that exists.
    public static func velocity(incoming: (speed: Double, influence: Double)?, outgoing: (speed: Double, influence: Double)?,
                                unit: String) -> KeyToolPrompt {
        var f: [Field] = []
        if let i = incoming {
            f.append(Field(label: "In speed (\(unit)/s)", text: ControlsNumberText.format(i.speed, decimals: 2)))
            f.append(Field(label: "In influence (%)", text: ControlsNumberText.format(i.influence * 100, decimals: 0)))
        }
        if let o = outgoing {
            f.append(Field(label: "Out speed (\(unit)/s)", text: ControlsNumberText.format(o.speed, decimals: 2)))
            f.append(Field(label: "Out influence (%)", text: ControlsNumberText.format(o.influence * 100, decimals: 0)))
        }
        return KeyToolPrompt(title: "Keyframe Velocity", informative: "Speed and influence of the incoming and outgoing side of the selected keys.",
                             confirm: "Apply", fields: f)
    }

    /// The answers of `velocity(...)`: per side (speed, influence 0...1), nil where the side is absent or unreadable.
    public static func velocityAnswer(_ texts: [String], hasIncoming: Bool, hasOutgoing: Bool)
        -> (incoming: (speed: Double, influence: Double)?, outgoing: (speed: Double, influence: Double)?) {
        func read(_ i: Int) -> (speed: Double, influence: Double)? {
            guard i + 1 < texts.count, let sp = KeyToolsInput.number(texts[i]), let inf = KeyToolsInput.number(texts[i + 1]) else { return nil }
            return (abs(sp), min(max(inf / 100, 0.0001), 1))
        }
        return (hasIncoming ? read(0) : nil, hasOutgoing ? read(hasIncoming ? 2 : 0) : nil)
    }
}
