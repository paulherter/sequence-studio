import Foundation
import Metal
import SQRender

/// Draws the resolved (count/max) float textures of `ScopeResources` with a phosphor-like intensity + glow mapping.
/// Device-bound, no AppKit. Graticules are NOT drawn here (see `ScopeOverlayView`).
public final class ScopeRenderer: @unchecked Sendable {
    public let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    public static let colorFormat: MTLPixelFormat = .bgra8Unorm
    /// Background = Theme viewer color.
    public static let background: MTLClearColor = {
        let c = Theme.Colors.viewer.usingColorSpace(.sRGB) ?? Theme.Colors.viewer
        return MTLClearColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: 1)
    }()

    public init(device: MTLDevice) throws {
        self.device = device
        let lib = try device.makeLibrary(source: Self.source, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "scopeVS")
        d.fragmentFunction = lib.makeFunction(name: "scopeFS")
        d.colorAttachments[0].pixelFormat = Self.colorFormat
        pipeline = try device.makeRenderPipelineState(descriptor: d)
    }

    private struct Params {
        var mode: UInt32 = 0          // 0 luma, 1 parade, 2 vectorscope, 3 histogram
        var gain: Float = 1
        var texel: SIMD2<Float> = .zero
    }

    /// Encodes one render pass into `target` (cleared to the viewer background).
    public func encode(kind: ScopeKind, resources r: ScopeResources, target: MTLTexture,
                       intensity: Float = 1, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.background
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let tex: MTLTexture
        switch kind {
        case .waveform: tex = r.waveformLuma
        case .parade: tex = r.waveformParade
        case .vectorscope: tex = r.vectorscope
        case .histogram: tex = r.histogram
        }
        var p = Params(mode: UInt32(kind.rawValue), gain: intensity, texel: SIMD2(1 / Float(tex.width), 1 / Float(tex.height)))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    struct Params { uint mode; float gain; float2 texel; };
    vertex VOut scopeVS(uint vid [[vertex_id]]) {
        float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);   // strip: TL, TR, BL, BR
        VOut o; o.pos = float4(p, 0, 1); o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return o;
    }
    // count/max (0...1) -> display intensity: compressive so sparse traces stay visible.
    static float map(float v, float gain) { return saturate(pow(v, 0.45) * 1.6 * gain); }
    // Vectorscope: log over five decades with a visible floor for any occupied bin. A real picture piles most pixels into
    // the neutral center bin (count/max of an outlying color is 1e-4 or less); a linear-ish map made everything but the
    // center vanish ("vectorscope shows nothing").
    static float mapVector(float v, float gain) {
        if (v <= 0.0) { return 0.0; }
        return saturate((0.34 + 0.66 * saturate(1.0 + log10(v) / 5.0)) * gain);
    }
    // core + 4-tap cross glow
    static float sampleGlow(texture2d<float> t, sampler s, float2 uv, float2 texel, float gain, float2 scale, bool vec) {
        float c = vec ? mapVector(t.sample(s, uv).r, gain) : map(t.sample(s, uv).r, gain);
        float g = 0;
        float4 v = float4(t.sample(s, uv + float2(texel.x * scale.x, 0)).r, t.sample(s, uv - float2(texel.x * scale.x, 0)).r,
                          t.sample(s, uv + float2(0, texel.y * scale.y)).r, t.sample(s, uv - float2(0, texel.y * scale.y)).r);
        for (int k = 0; k < 4; k++) { g += vec ? mapVector(v[k], gain) : map(v[k], gain); }
        return saturate(c + 0.18 * g);
    }
    fragment float4 scopeFS(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant Params& p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 bg = float3(12.0 / 255.0);
        float3 col = bg;
        if (p.mode == 0) {                       // luma waveform: phosphor green-white
            float i = sampleGlow(t, s, in.uv, p.texel, p.gain, float2(1.5, 1.5), false);
            col = bg + i * float3(0.62, 1.0, 0.72);
        } else if (p.mode == 1) {                // parade: three panels tinted R, G, B
            float panel = min(floor(in.uv.x * 3.0), 2.0);
            float i = sampleGlow(t, s, in.uv, p.texel, p.gain, float2(1.0, 1.5), false);
            float3 tint = panel < 0.5 ? float3(1.0, 0.30, 0.26) : (panel < 1.5 ? float3(0.30, 1.0, 0.42) : float3(0.30, 0.52, 1.0));
            col = bg + i * tint;
        } else if (p.mode == 2) {                // vectorscope
            float i = sampleGlow(t, s, in.uv, p.texel, p.gain, float2(1.5, 1.5), true);
            col = bg + i * float3(0.70, 1.0, 0.80);
        } else {                                 // histogram: R, G, B, Y filled curves, additive
            float x = in.uv.x, h = 1.0 - in.uv.y;
            float rows[4];
            for (int r = 0; r < 4; r++) {
                float v = t.sample(s, float2(x, (float(r) + 0.5) / 4.0)).r;
                rows[r] = sqrt(v);
            }
            float3 add = float3(0);
            if (h <= rows[0]) add += float3(0.85, 0.12, 0.10);
            if (h <= rows[1]) add += float3(0.10, 0.75, 0.22);
            if (h <= rows[2]) add += float3(0.12, 0.30, 0.95);
            if (h <= rows[3]) add += float3(0.22);
            col = bg + add * p.gain;
        }
        return float4(saturate(col), 1.0);
    }
    """
}
