import AppKit
import QuartzCore
import SQDrawKit
import SQRender
import SQUIKit

/// The CAMetalLayer view under the draw UI that shows the Program or Source picture. The playback engine presents into its
/// layer (`ProgramEngine.attach(metalLayer)`); the view only keeps the layer sized to the view in device pixels and tells
/// the owner when the drawable size changed, so the engine redraws the current frame at the new size.
final class MacPictureView: NSView {
    /// Called on the main thread whenever the drawable size changed.
    var onResize: (() -> Void)?
    private var lastDrawableSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { ShapedMetalLayer() }
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { true }
    /// The backing layer, for `ProgramEngine.attach`.
    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private func configureLayer() {
        guard let ml = metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ml.contentsScale = scale
        // Until the new size is presented the layer shows the old drawable: never stretch it (aspect-fit, not resize).
        ml.contentsGravity = .resizeAspect
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        ml.drawableSize = size
        if size != lastDrawableSize { lastDrawableSize = size; onResize?() }
        ml.presentsWithTransaction = false
        if ml.colorspace == nil { ml.colorspace = Presenter.displayColorSpace }   // COL-04, also before a presenter attaches
        ml.backgroundColor = MacWindowStyle.color(DrawColor(hex: SQTokens.Hex.monitorBackdrop)).cgColor
    }

    override func layout() { super.layout(); configureLayer() }
    /// Resizing and re-parenting (Edit <-> Color, panel drags) update the drawable size at once, not at the next layout pass.
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); configureLayer() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configureLayer() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); configureLayer() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureLayer() }
}
