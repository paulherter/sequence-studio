#if canImport(Metal)
import CoreGraphics
import CoreVideo
import Metal
import QuartzCore
import SQCore
import SQGPU
import SQGPUKernels
import SQGPUMetal

// ViewerZoom and its destination rect live in SQCore (portable: the Windows monitor uses the same math).

/// Draws the compositor's rgba16Float working-linear texture into a CAMetalLayer drawable.
///
/// Output transform (COL-04): the compositor applied the inverse BT.709 OETF at input, so the presenter applies the
/// forward BT.709 OETF and writes BT.709 code values into the layer's BGRA8 drawable. The layer is tagged with
/// `displayColorSpace`, so the window server color-manages them to the actual display (P3 MacBooks included) the same
/// way QuickTime shows an exported 1-1-1 file. HLG/PQ sources arrive here already tone-mapped to SDR.
public final class Presenter: @unchecked Sendable {
    public static let drawablePixelFormat: MTLPixelFormat = .bgra8Unorm

    /// The space macOS itself uses for 1-1-1 (BT.709 primaries, transfer, matrix) video: CoreVideo's mapping, which
    /// QuickTime/AVFoundation display through (`kCGColorSpaceCoreMedia709`, effective gamma ~1.96). Falls back to
    /// `itur_709` if CoreVideo returns nothing.
    public static var displayColorSpace: CGColorSpace { colorSpaceBox.space }
    private struct SpaceBox: @unchecked Sendable { let space: CGColorSpace }
    private static let colorSpaceBox: SpaceBox = {
        let attachments = [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                           kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                           kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2] as CFDictionary
        if let cs = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() { return SpaceBox(space: cs) }
        return SpaceBox(space: CGColorSpace(name: CGColorSpace.itur_709)!)
    }()

    /// Viewer surround: sRGB #2C2C2C (`Theme.Colors.monitorBackdrop`, clearly lighter than the picture's black so the frame
    /// edge shows) expressed in `displayColorSpace`, so after color management it still matches the surrounding UI.
    public static let surround: MTLClearColor = {
        let v = 44.0 / 255
        let srgb = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [v, v, v, 1])!
        guard let c = srgb.converted(to: displayColorSpace, intent: .relativeColorimetric, options: nil)?.components,
              c.count >= 3 else { return MTLClearColor(red: v, green: v, blue: v, alpha: 1) }
        return MTLClearColor(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: 1)
    }()

    /// Tests: pins the view gamma of this presenter instead of following the shared monitor choice.
    var viewGammaOverride: ViewGamma?
    /// Tests: pins the display view of this presenter instead of following `DisplayView.current`.
    var displayViewOverride: DisplayView?
    public let device: MTLDevice
    public let layer: CAMetalLayer?
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    /// The Slang draw (Present.slang) and its fixed samplers.
    private let gpu: MetalGPUDevice

    public init(device: MTLDevice, layer: CAMetalLayer) {
        self.device = device
        self.layer = layer
        layer.device = device
        layer.pixelFormat = Self.drawablePixelFormat
        layer.colorspace = Self.displayColorSpace
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        gpu = try! MetalGPUDevice(device: device)
    }

    /// Layer-less presenter for offscreen rendering (tests, export previews).
    public init(device: MTLDevice) {
        self.device = device
        self.layer = nil
        gpu = try! MetalGPUDevice(device: device)
    }

    /// Pulls the next drawable from the layer, encodes and schedules presentation.
    public func present(_ texture: MTLTexture, zoom: ViewerZoom, commandBuffer: MTLCommandBuffer) {
        guard let layer else { return }
        configure(layer, for: displayViewOverride ?? DisplayView.current)
        guard let drawable = layer.nextDrawable() else { return }
        present(texture, zoom: zoom, drawable: drawable, commandBuffer: commandBuffer)
    }

    /// Variant for CAMetalDisplayLink, which hands over the drawable.
    public func present(_ texture: MTLTexture, zoom: ViewerZoom, drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        if let layer { configure(layer, for: displayViewOverride ?? DisplayView.current) }   // takes effect from the next drawable
        encode(texture, zoom: zoom, target: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
    }

    /// Sets the layer's drawable format and tag for the view (only what changed).
    private func configure(_ layer: CAMetalLayer, for view: DisplayView) {
        if layer.pixelFormat != view.pixelFormat { layer.pixelFormat = view.pixelFormat }
        if layer.wantsExtendedDynamicRangeContent != view.isExtendedRange { layer.wantsExtendedDynamicRangeContent = view.isExtendedRange }
        let space = view.colorSpace
        if layer.colorspace.map({ !CFEqual($0, space) }) ?? true { layer.colorspace = space }
    }

    /// Core: clears `target` to the surround and draws `texture` into `destinationRect`. Target must be a
    /// renderable 8-bit or float color format.
    public func encode(_ texture: MTLTexture, zoom: ViewerZoom, target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let pso = pipeline(for: target.pixelFormat) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.surround
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Non-square pixels: the picture is shown at its display aspect (the layer carries the shape); square: unchanged.
        let shownWidth = (layer as? ShapedMetalLayer)?.displayWidth(ofStored: texture.width) ?? texture.width
        let r = Self.destinationRect(textureSize: CGSize(width: shownWidth, height: texture.height),
                                     drawableSize: CGSize(width: target.width, height: target.height), zoom: zoom)
        let clipped = r.intersection(CGRect(x: 0, y: 0, width: target.width, height: target.height))
        if !clipped.isNull, clipped.width >= 1, clipped.height >= 1 {
            enc.setRenderPipelineState(pso)
            enc.setViewport(MTLViewport(originX: r.minX, originY: r.minY, width: r.width, height: r.height,
                                        znear: 0, zfar: 1))
            let x = Int(clipped.minX.rounded(.down)), y = Int(clipped.minY.rounded(.down))
            let w = min(target.width - x, Int(clipped.maxX.rounded(.up)) - x)
            let h = min(target.height - y, Int(clipped.maxY.rounded(.up)) - y)
            enc.setScissorRect(MTLScissorRect(x: x, y: y, width: max(w, 1), height: max(h, 1)))
            gpu.bindSamplers(enc)
            enc.setFragmentTexture(texture, index: 0)
            var useNearest = false
            if case .percent(let p) = zoom, p >= 100 { useNearest = true }
            if case .view(let s, _, _) = zoom, s >= 1 { useNearest = true }
            let view = displayViewOverride ?? DisplayView.current
            let m = Gamut.rec709.matrix(to: view.gamut)
            var params = PresentUniforms(m0: SIMD4(m.columns.0, 0), m1: SIMD4(m.columns.1, 0), m2: SIMD4(m.columns.2, 0),
                                         mode: view.mode, peak: DisplayView.hdrPeak, knee: ToneMapping().knee,
                                         exponent: (viewGammaOverride ?? ViewGamma.current).exponent,   // monitor preview only
                                         nearest: useNearest ? 1 : 0)
            enc.setVertexBytes(&params, length: MemoryLayout<PresentUniforms>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<PresentUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    /// Mirrors `PresentU` in Present.slang (columns of the Rec.709 -> view primaries matrix, padded to float4).
    private struct PresentUniforms {
        var m0: SIMD4<Float>, m1: SIMD4<Float>, m2: SIMD4<Float>
        var mode: Float, peak: Float, knee: Float
        var exponent: Float
        var nearest: UInt32
    }

    private func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = pipelines[format] { return p }
        let kernel = GPURenderKernel(GeneratedShaders.present, vertex: "presentVertex", fragment: "presentFragment")
        guard let p = try? gpu.makeRenderPipeline(kernel, pixelFormat: format, blend: .replace).state else { return nil }
        pipelines[format] = p
        return p
    }

    /// Destination rectangle in drawable pixels (origin top-left). Fit scales to the drawable (up or down)
    /// preserving aspect; `.percent(p)` is p/100 drawable px per texture px. Centered, origin snapped to whole pixels.
    public static func destinationRect(textureSize: CGSize, drawableSize: CGSize, zoom: ViewerZoom) -> CGRect {
        zoom.destinationRect(textureSize: textureSize, drawableSize: drawableSize)
    }
}
#endif
