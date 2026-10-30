import Foundation

#if !canImport(CoreGraphics)
/// swift-corelibs-foundation (Windows, Linux) has CGFloat, CGPoint, CGSize and CGRect but no CGVector; the monitor
/// geometry shared with the Mac uses it for the layer axes.
public struct CGVector: Sendable, Equatable, Hashable {
    public var dx: CGFloat, dy: CGFloat
    public init(dx: CGFloat, dy: CGFloat) { self.dx = dx; self.dy = dy }
    public static let zero = CGVector(dx: CGFloat(0), dy: CGFloat(0))
}
#endif
