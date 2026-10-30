import Foundation

/// Fit Clip choice for a four-mark Source edit (Fit to Fill by speed is `fitToFill` on the session). Each case drops one
/// of the four marks so the remaining three decide the edit.
public enum FourPointFit: Sendable, Equatable, CaseIterable {
    /// Default: sequence In/Out set the range, the source In picks the part (the source Out is ignored).
    case trimSourceEnd
    /// The source Out and the sequence range are used; the source In is ignored.
    case ignoreSourceIn
    /// Source In/Out give the length, placed at the sequence In; the sequence Out is ignored.
    case ignoreSequenceOut
    /// Source In/Out give the length, ending at the sequence Out; the sequence In is ignored.
    case ignoreSequenceIn

    /// The marks left after dropping one.
    public func apply(source m: SourceMarks, sequenceIn: Time?, sequenceOut: Time?)
        -> (source: SourceMarks, sequenceIn: Time?, sequenceOut: Time?) {
        var m = m, si = sequenceIn, so = sequenceOut
        switch self {
        case .trimSourceEnd: break
        case .ignoreSourceIn: m.markIn = nil
        case .ignoreSequenceOut: so = nil
        case .ignoreSequenceIn: si = nil
        }
        return (m, si, so)
    }
}
