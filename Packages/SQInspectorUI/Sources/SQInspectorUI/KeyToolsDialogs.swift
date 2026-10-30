import AppKit
import SQCore
import SQUIKit

/// SQ-design dialogs for the key tools of the keyframe lanes and the Graph Editor.
@MainActor
enum KeyToolsDialogs {
    /// One prompt (`KeyToolPrompt`) as an SQ dialog: the typed texts in field order, nil when canceled.
    static func run(_ p: KeyToolPrompt) -> [String]? {
        let d = SQDialog()
        d.messageText = p.title
        d.informativeText = p.informative
        let fields = p.fields.map { SQDialog.makeField($0.text, width: nil) }
        if !fields.isEmpty { d.accessoryView = SQDialogForm(rows: zip(p.fields, fields).map { SQDialog.formRow($0.label, $1) }) }
        d.addButton(p.confirm)
        d.addButton("Cancel")
        d.initialFirstResponder = fields.first
        guard d.runModal() == .first else { return nil }
        return fields.map(\.stringValue)
    }

    /// Scale Time: percent of the keys' distance to the earliest selected key. Returns the ratio, nil when canceled.
    static func runScaleTime() -> (num: Int64, den: Int64)? {
        run(.scaleTime).flatMap { KeyToolsInput.timeScaleRatio($0[0]) }
    }

    typealias Side = (speed: Double, influence: Double)

    /// Keyframe Velocity: speed in display units per second and influence in percent for the incoming and outgoing side.
    static func runVelocity(incoming: Side?, outgoing: Side?, unit: String) -> (incoming: Side?, outgoing: Side?)? {
        run(.velocity(incoming: incoming, outgoing: outgoing, unit: unit))
            .map { KeyToolPrompt.velocityAnswer($0, hasIncoming: incoming != nil, hasOutgoing: outgoing != nil) }
    }

    /// Loop: how many more repeats of the key pattern (1...100); nil when canceled or invalid.
    static func runLoop() -> Int? {
        run(.loop).flatMap { KeyToolsInput.wholeNumber($0[0], in: 1...100) }
    }

    /// Wiggle: frequency (keys per second), amount (property units) and seed; nil when canceled or invalid.
    static func runWiggle() -> (perSecond: Int, amount: Double, seed: UInt64)? {
        run(.wiggle).flatMap { KeyToolsInput.wiggle(frequency: $0[0], amount: $0[1], seed: $0[2]) }
    }
}
