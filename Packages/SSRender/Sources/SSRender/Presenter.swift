import CoreGraphics
import Metal
import QuartzCore

/// `fit`: aspect-fitted. `percent(p)`: p/100 drawable px per texture px, centred. `view`: free zoom and pan,
/// `scale` = drawable px per texture px, `centerX/Y` = the texture offset (from its centre) shown at the drawable centre.
public enum ViewerZoom: Sendable, Hashable { case fit, percent(Int), view(scale: Double, centerX: Double, centerY: Double) }

/// Draws the compositor's rgba16Float working-linear texture into a CAMetalLayer drawable.
///
/// Output transform (Phase 2, "tagged Rec.709, gamma as decoded"): the compositor applied the inverse BT.709 OETF
/// at input, so the presenter applies the forward BT.709 OETF and writes the result unmanaged into the layer's
/// BGRA8 drawable. Phase 3 replaces this stage with a ColorSync/display transform.
/// The surround is written as the literal display code value #0C0C0C (no transfer function).
public final class Presenter: @unchecked Sendable {
    public static let drawablePixelFormat: MTLPixelFormat = .bgra8Unorm
    /// Viewer surround #0C0C0C as display code values.
    public static let surround = MTLClearColor(red: 12.0 / 255, green: 12.0 / 255, blue: 12.0 / 255, alpha: 1)

    public let device: MTLDevice
    public let layer: CAMetalLayer?
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState
    private let library: MTLLibrary

    public init(device: MTLDevice, layer: CAMetalLayer) {
        self.device = device
        self.layer = layer
        layer.device = device
        layer.pixelFormat = Self.drawablePixelFormat
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        (self.library, self.nearest, self.linear) = Self.makeShared(device)
    }

    /// Layer-less presenter for offscreen rendering (tests, export previews).
    public init(device: MTLDevice) {
        self.device = device
        self.layer = nil
        (self.library, self.nearest, self.linear) = Self.makeShared(device)
    }

    private static func makeShared(_ device: MTLDevice) -> (MTLLibrary, MTLSamplerState, MTLSamplerState) {
        let lib = try! device.makeLibrary(source: shaderSource, options: nil)
        func sampler(_ f: MTLSamplerMinMagFilter) -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = f; d.magFilter = f
            d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: d)!
        }
        return (lib, sampler(.nearest), sampler(.linear))
    }

    /// Pulls the next drawable from the layer, encodes and schedules presentation.
    public func present(_ texture: MTLTexture, zoom: ViewerZoom, commandBuffer: MTLCommandBuffer) {
        guard let layer, let drawable = layer.nextDrawable() else { return }
        present(texture, zoom: zoom, drawable: drawable, commandBuffer: commandBuffer)
    }

    /// Variant for CAMetalDisplayLink, which hands over the drawable.
    public func present(_ texture: MTLTexture, zoom: ViewerZoom, drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        encode(texture, zoom: zoom, target: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
    }

    /// Core: clears `target` to the surround and draws `texture` into `destinationRect`. Target must be a
    /// renderable 8-bit or float colour format.
    public func encode(_ texture: MTLTexture, zoom: ViewerZoom, target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let pso = pipeline(for: target.pixelFormat) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.surround
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let r = Self.destinationRect(textureSize: CGSize(width: texture.width, height: texture.height),
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
            enc.setFragmentTexture(texture, index: 0)
            var useNearest = false
            if case .percent(let p) = zoom, p >= 100 { useNearest = true }
            if case .view(let s, _, _) = zoom, s >= 1 { useNearest = true }
            enc.setFragmentSamplerState(useNearest ? nearest : linear, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    private func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = pipelines[format] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "presentVertex")
        d.fragmentFunction = library.makeFunction(name: "presentFragment")
        d.colorAttachments[0].pixelFormat = format
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipelines[format] = p
        return p
    }

    /// Destination rectangle in drawable pixels (origin top-left). Fit scales to the drawable (up or down)
    /// preserving aspect; `.percent(p)` is p/100 drawable px per texture px. Centred, origin snapped to whole pixels.
    public static func destinationRect(textureSize: CGSize, drawableSize: CGSize, zoom: ViewerZoom) -> CGRect {
        guard textureSize.width > 0, textureSize.height > 0, drawableSize.width > 0, drawableSize.height > 0 else { return .zero }
        let scale: CGFloat
        var cx: CGFloat = 0, cy: CGFloat = 0
        switch zoom {
        case .fit: scale = min(drawableSize.width / textureSize.width, drawableSize.height / textureSize.height)
        case .percent(let p): scale = CGFloat(max(p, 1)) / 100
        case .view(let s, let x, let y): scale = CGFloat(max(s, 0.001)); cx = CGFloat(x); cy = CGFloat(y)
        }
        let w = textureSize.width * scale, h = textureSize.height * scale
        let x = ((drawableSize.width - w) / 2 - cx * scale).rounded(), y = ((drawableSize.height - h) / 2 - cy * scale).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut presentVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);          // full-viewport triangle
        VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
    }
    inline float3 oetf709(float3 l) {
        l = max(l, 0.0f);
        return select(1.09929682680944f * pow(l, 0.45f) - 0.09929682680944f, 4.5f * l, l < 0.018053968510807f);
    }
    fragment float4 presentFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float3 lin = tex.sample(s, in.uv).rgb;
        return float4(saturate(oetf709(lin)), 1.0);
    }
    """
}
