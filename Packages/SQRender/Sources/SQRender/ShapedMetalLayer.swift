#if canImport(Metal)
import Foundation
import QuartzCore
import SQCore

/// The Program monitor's layer. It carries the sequence's pixel shape so the `Presenter` (owned by the playback engine,
/// which only knows the layer) draws the stored texture at its display aspect. Square pixels: `nil`, nothing changes.
public final class ShapedMetalLayer: CAMetalLayer, @unchecked Sendable {
    private let lock = NSLock()
    private var shape: PixelAspect?

    public override init() { super.init() }
    public override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? ShapedMetalLayer { shape = other.pixelAspect.isSquare ? nil : other.pixelAspect }   // CA presentation copies keep the shape
    }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    /// Set by the monitor when the active sequence changes.
    public var pixelAspect: PixelAspect {
        get { lock.lock(); defer { lock.unlock() }; return shape ?? .square }
        set { lock.lock(); shape = newValue.isSquare ? nil : newValue; lock.unlock() }
    }

    /// Width the stored texture is shown at (same even rounding as `SequenceFormat.displayWidth`).
    func displayWidth(ofStored w: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return shape?.displayWidth(ofStored: w) ?? w
    }
}
#endif
