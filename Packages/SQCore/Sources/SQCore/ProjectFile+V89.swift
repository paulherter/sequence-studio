import Foundation

// v89: a reversed transition (`Transition.reversed`, `TransitionLayer.reversed`): the move or wipe travels the other way.
// A v88 build would play it forwards and drop the flag on the next save; at v89 it refuses the file with
// `ProjectFileError.newerVersion` instead. A transition that is not reversed stores no key, so such files keep the lowest
// version that holds their content (byte-identical). Identity step: the key is optional on decode.

extension TransitionDirection {
    /// The way back along the same axis.
    public var opposite: TransitionDirection {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }
}

extension Transition {
    public var isReversed: Bool { reversed == true }
    /// The direction the render travels: the style's direction, turned around when reversed.
    public var renderDirection: TransitionDirection { isReversed ? effectiveDirection.opposite : effectiveDirection }
}

extension TransitionLayer {
    public var isReversed: Bool { reversed == true }
    public var renderDirection: TransitionDirection { isReversed ? effectiveDirection.opposite : effectiveDirection }
}

extension Project {
    /// Any clip-edge transition or transition layer is reversed: the file must be v89.
    public var containsV89Content: Bool {
        timelines.contains { tl in
            tl.tracks.contains { t in
                t.transitions.contains(where: \.isReversed) || t.clips.contains { $0.transitionLayer?.isReversed == true }
            }
        }
    }
}
