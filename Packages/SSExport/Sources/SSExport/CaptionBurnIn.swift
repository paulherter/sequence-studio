import CoreVideo
import Foundation
import Metal
import SSCore
import SSText
import SSTranscribe
import simd

/// Where the caption block sits on the canvas.
public struct CaptionPlacement: Sendable, Hashable {
    /// Distance from the canvas bottom to the bottom of the text block, as a fraction of the canvas height
    /// (default: bottom safe area, clear of platform UI on 9:16).
    public var bottomMargin: Double
    /// Wrap width as a fraction of the canvas width.
    public var maxWidthFraction: Double
    public init(bottomMargin: Double = 0.12, maxWidthFraction: Double = 0.86) {
        self.bottomMargin = bottomMargin; self.maxWidthFraction = maxWidthFraction
    }
    public static let bottomSafeArea = CaptionPlacement()
}

/// What to draw for one frame: which caption, and its animation state at that time.
public struct CaptionDrawState: Sendable, Equatable {
    public var index: Int
    public var opacity: Double
    public var scale: Double
}

/// Burns captions into the working-linear frame (before the output encode). Text is rasterized once per caption
/// with SSText `TextRenderer` (sequence pixel size), uploaded as a premultiplied linear rgba16Float texture and
/// drawn as a quad whose opacity/scale come from the caption's animation template evaluated at the frame time.
public final class CaptionBurnIn: @unchecked Sendable {
    public let captions: [Caption]
    public let placement: CaptionPlacement
    private let style: @Sendable (String) -> TextStyle
    private let animation: @Sendable (String) -> KeyframeTemplate?
    private let lock = NSLock()
    private struct Cached { var texture: MTLTexture; var originX: Double, originY: Double }
    private var textures: [Int: Cached] = [:]
    private var pipeline: MTLRenderPipelineState?
    private var device: MTLDevice?

    public init(captions: [Caption], placement: CaptionPlacement = .bottomSafeArea,
                style: @escaping @Sendable (String) -> TextStyle,
                animation: @escaping @Sendable (String) -> KeyframeTemplate?) {
        self.captions = captions.sorted { $0.range.start < $1.range.start }
        self.placement = placement; self.style = style; self.animation = animation
    }

    public convenience init(captions: [Caption], library: CaptionPresetLibrary,
                            placement: CaptionPlacement = .bottomSafeArea) {
        self.init(captions: captions, placement: placement,
                  style: { library.style(for: $0) }, animation: { library.animation(for: $0) })
    }

    /// The caption showing at `t` with opacity/scale, or nil. Pure (no GPU).
    public func state(at t: Time) -> CaptionDrawState? {
        guard let i = captions.firstIndex(where: { $0.range.contains(t) }) else { return nil }
        let c = captions[i]
        var opacity = 1.0, scale = 1.0
        if let a = animation(c.animationRef) {
            let local = t - c.range.start
            opacity = a.value(of: "opacity", clipTime: local, clipDuration: c.range.duration) ?? 1
            scale = a.value(of: "scale", clipTime: local, clipDuration: c.range.duration) ?? 1
        }
        return CaptionDrawState(index: i, opacity: min(1, max(0, opacity)), scale: max(0, scale))
    }

    // MARK: GPU

    private func makePipeline(_ device: MTLDevice) throws -> MTLRenderPipelineState {
        if let pipeline, self.device === device { return pipeline }
        let lib = try device.makeLibrary(source: ExportShaderSource.msl, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "overlayVertex")
        d.fragmentFunction = lib.makeFunction(name: "overlayFragment")
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = .rgba16Float
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let p = try device.makeRenderPipelineState(descriptor: d)
        pipeline = p; self.device = device
        return p
    }

    private func texture(for index: Int, canvasWidth: Int, canvasHeight: Int, device: MTLDevice) throws -> Cached? {
        if let t = textures[index] { return t }
        let c = captions[index]
        // Same template and box as the Program monitor (`CaptionLayout`).
        let template = CaptionLayout.template(text: c.lines.joined(separator: "\n"), style: style(c.styleRef),
                                              canvasWidth: Double(canvasWidth), canvasHeight: Double(canvasHeight),
                                              widthFraction: placement.maxWidthFraction)
        guard let raster = try TextRenderer.render(text: template.text, style: template.style, maxWidth: template.box?.width,
                                                   boxHeight: template.box?.height) else { return nil }
        let pb = raster.linearBuffer
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: raster.pixelWidth,
                                                         height: raster.pixelHeight, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { throw CompositorOverlayError.allocation }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        tex.replace(region: MTLRegionMake2D(0, 0, raster.pixelWidth, raster.pixelHeight), mipmapLevel: 0,
                    withBytes: CVPixelBufferGetBaseAddress(pb)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        if textures.count >= 8 { textures.removeAll() }
        let cached = Cached(texture: tex, originX: raster.originX, originY: raster.originY)
        textures[index] = cached
        return cached
    }

    /// Draws the caption active at `t` (if any) over `target` (rgba16Float, `.renderTarget`, working-linear).
    /// Returns whether something was drawn.
    @discardableResult
    public func encode(at t: Time, into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> Bool {
        guard let s = state(at: t), s.opacity > 0, s.scale > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        let device = target.device
        guard let cached = try texture(for: s.index, canvasWidth: target.width, canvasHeight: target.height, device: device)
        else { return false }
        let tex = cached.texture
        let pipe = try makePipeline(device)
        let w = Float(target.width), h = Float(target.height)
        let size = SIMD2(Float(tex.width), Float(tex.height))
        // Where the monitor puts the raster: inside the shared caption box (`CaptionLayout`); its centre is the pivot.
        let c = CaptionLayout.rasterCentre(canvasWidth: Double(w), canvasHeight: Double(h), originX: cached.originX,
                                           originY: cached.originY, width: Double(size.x), height: Double(size.y),
                                           widthFraction: placement.maxWidthFraction, bottomMargin: placement.bottomMargin)
        let center = SIMD2(Float(c.x), Float(c.y))
        var u = OverlayUniforms(canvas: SIMD2(w, h), center: center, size: size, scale: Float(s.scale),
                                opacity: Float(s.opacity))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw CompositorOverlayError.allocation }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBytes(&u, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return true
    }
}

enum CompositorOverlayError: Error { case allocation }

struct OverlayUniforms {
    var canvas: SIMD2<Float>
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var scale: Float
    var opacity: Float
}
