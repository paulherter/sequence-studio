import SQCore

/// The Sharpen row of Color Basic (the maintainer's grade: Sharpen 20). It is backed by the ordinary Sharpen effect of the
/// graded clip (`ClipEffect.sharpenKind`, Amount 0...100 in the row), so Effect Controls shows the same value and no
/// project data changes.
extension Clip {
    /// Row range: Sharpen in the Color panel runs 0...100 (the effect itself goes to 4000).
    public static let sharpenRowRange: ClosedRange<Float> = 0...100

    /// Amount of the clip's first Sharpen effect (0 = none or neutral).
    public var sharpenAmount: Float {
        guard let e = effects.first(where: { $0.kind == ClipEffect.sharpenKind }) else { return 0 }
        return Float(e.parameters[ClipEffect.sharpenAmountKey]?.value ?? 0)
    }

    /// Sets the Sharpen amount; adds the effect when there is none and `amount` is not 0. False when nothing changed.
    /// shortcut: the value is static (a keyed Sharpen keeps its keys and is not edited here), upgrade with the Color
    /// keyframe controls when the maintainer animates Sharpen.
    @discardableResult
    public mutating func setSharpenAmount(_ amount: Float) -> Bool {
        let v = Double(min(max(amount, Self.sharpenRowRange.lowerBound), Self.sharpenRowRange.upperBound))
        if let i = effects.firstIndex(where: { $0.kind == ClipEffect.sharpenKind }) {
            guard effects[i].parameters[ClipEffect.sharpenAmountKey]?.value != v else { return false }
            effects[i].parameters[ClipEffect.sharpenAmountKey] = AnimatedProperty(v)
            return true
        }
        guard v != 0, var e = ClipEffect.make(kind: ClipEffect.sharpenKind) else { return false }
        e.parameters[ClipEffect.sharpenAmountKey] = AnimatedProperty(v)
        effects.append(e)
        return true
    }
}
