import AppKit
import Metal
import QuartzCore
import SSRender
import os

/// Program/Source viewer surface: CAMetalLayer-backed, drawn from a render thread driven by CAMetalDisplayLink.
/// `frameProvider` runs on the render thread once per display refresh; it encodes into the given command buffer
/// (e.g. `Compositor.render`) and returns the rgba16Float texture to show, or nil to keep the last frame.
public final class ViewerView: NSView {
    public typealias FrameProvider = @Sendable (MTLCommandBuffer) -> MTLTexture?

    private let state = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var provider: FrameProvider?
        var zoom: ViewerZoom = .fit
    }
    private var driver: RenderDriver?
    public let device: MTLDevice?
    /// false: another renderer (the playback engine, via `ProgramEngine.attach(metalLayer)`) presents into the layer;
    /// the view then only keeps the layer sized. Set before the view enters a window.
    public var drivesLayer = true

    public var frameProvider: FrameProvider? {
        get { state.withLock { $0.provider } }
        set { state.withLock { $0.provider = newValue } }
    }
    /// Called on the main thread whenever the drawable size changed (the owner re-presents the current frame so the
    /// picture is redrawn, aspect-fitted, at the new size instead of the old drawable being stretched).
    public var onResize: (() -> Void)?
    private var lastDrawableSize: CGSize = .zero

    public var zoom: ViewerZoom {
        get { state.withLock { $0.zoom } }
        set { state.withLock { $0.zoom = newValue } }
    }

    public override init(frame: NSRect) {
        device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    public override var wantsUpdateLayer: Bool { true }
    public override var isOpaque: Bool { true }
    /// The backing layer, for `ProgramEngine.attach`.
    public var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

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
        ml.backgroundColor = Theme.Colors.viewer.cgColor
    }

    public override func layout() { super.layout(); configureLayer() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); configureLayer() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { driver?.stop(); driver = nil; return }
        guard drivesLayer, driver == nil, let device, let ml = metalLayer, let queue = device.makeCommandQueue() else { return }
        configureLayer()
        let presenter = Presenter(device: device, layer: ml)
        let d = RenderDriver(layer: ml, presenter: presenter, queue: queue) { [weak self] in
            self?.state.withLock { ($0.provider, $0.zoom) } ?? (nil, .fit)
        }
        driver = d
        d.start()
    }

    deinit { driver?.stop() }
}

private final class RenderDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    let layer: CAMetalLayer
    let presenter: Presenter
    let queue: MTLCommandQueue
    let snapshot: @Sendable () -> (ViewerView.FrameProvider?, ViewerZoom)
    private var thread: Thread?
    private let link = LinkBox()

    init(layer: CAMetalLayer, presenter: Presenter, queue: MTLCommandQueue,
         snapshot: @escaping @Sendable () -> (ViewerView.FrameProvider?, ViewerZoom)) {
        self.layer = layer; self.presenter = presenter; self.queue = queue; self.snapshot = snapshot
    }

    func start() {
        let t = Thread { [self] in
            let dl = CAMetalDisplayLink(metalLayer: layer)
            dl.delegate = self
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 120, preferred: 60)
            dl.add(to: .current, forMode: .common)
            link.value = dl
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            dl.invalidate()
        }
        t.name = "SS.ViewerRender"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() { thread?.cancel(); thread = nil; link.value?.isPaused = true }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let (provider, zoom) = snapshot()
        guard let provider, let cb = queue.makeCommandBuffer() else { return }
        guard let tex = provider(cb) else { return }
        presenter.present(tex, zoom: zoom, drawable: update.drawable, commandBuffer: cb)
        cb.commit()
    }
}

private final class LinkBox: @unchecked Sendable { nonisolated(unsafe) var value: CAMetalDisplayLink? }
