/// The compositor's source conversion in MSL, for the fused grade kernels that `ColorKernelSource` generates at runtime.
/// Every compositor kernel and draw is Slang (Packages/SQGPU/Shaders); the old MSL lives on in SQRenderTests
/// (`LegacyCompositorShaderSource`) for the parity tests. `CompositeUniforms` mirrors `Compositor.Uniforms` (224 bytes).
enum CompositorShaderSource {
    /// `CompositeUniforms` and the source conversion (`convertTexel`, `convertTexelScaled`), shared with the fused grade
    /// kernels (`ColorKernelSource`). Needs `ColorShaderSource.transferMSL` before it.
    static let convertMSL = """
    struct CompositeUniforms {
        float3x3 m;          // Y'CbCr -> R'G'B'
        float4 solid;        // placeholder color (working-linear)
        float4 range;        // yScale, yBias, cScale, cBias
        float2 canvas;       // sequence size, px
        float2 size;         // layer size, px (its own upright size, before transform scale)
        float2 position;     // offset from canvas center, px, y down
        float2 anchor;       // offset from layer center, px
        float2 scale;
        float rotCos, rotSin, opacity;
        uint mode;           // 0 = YCbCr bi-planar, 1 = RGB texture, 2 = solid, 3 = premultiplied RGBA group image (linear),
                             // 4 = packed AYCbCr 'y416' (alpha video)
        uint linearize;      // 1 = apply inverse BT.709 OETF (no color stage)
        float cornerRadius;  // layer-local px (before transform scale)
        uint quarter;        // clockwise quarter turns of the source picture (modes 0 and 1)
        uint blend;          // blend mode id (compositeFragmentBlend only): BlendModes.shaderID
        float2 maskSize;     // rectangle Crop / Rounded Corners work on, layer px; 0 = size
        float4 crop;         // left, top, right, bottom insets as fractions of maskSize
        float4 key0;         // Ultra Key: hue (deg), half width (deg), soft edge (deg), spill (0...1)
        float4 key1;
        float4 matte0;       // per key: shrink / grow, pedestal, output (0 composite, 1 alpha, 2 source), mode (0 chroma, 1 luma)
        float4 matte1;
        float4 shape0;       // per key: matte contrast, midpoint, keep highlights, keep shadows
        float4 shape1;
        float4 cc0;          // per key: saturation, hue shift (rad), brightness, spill range
        float4 cc1;
        uint keyCount;       // keys in use (0...2)
        uint roundFirst;     // 1 = round the whole frame first, then crop (Rounded Corners before Crop)
        uint alphaMode;      // texture alpha (modes 1, 4): 0 = legacy (mode 1: premultiplied when linearize, else straight),
                             // 1 = straight, 2 = premultiplied; 1 and 2 filter premultiplied color (no fringes)
        uint maskCount;      // W6.7 clip masks in the mask buffer (fragment buffer 1); 0 = none
        float cropFeather;   // Crop Softness: the mask edge ramp widens inwards by this many layer px; 0 = hard edge
        float4 part;         // mode 3, a partial buffer drawn as the whole picture: its place in it (xy, texels) and the
                             // whole picture's size (zw, texels); z = 0: the texture is the whole picture
        float3 tilt;         // perspective tilt: x, y radians about the anchor, camera distance px (z = 0: flat)
    };

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    // Column by column, as the Slang source conversion (Parts/Convert.slang) writes it: `u.m * v` rounds differently, and the
    // fused grade must match the generic path's Slang convert pass byte for byte (GradeFusionTests).
    inline float3 ycbcrToRGB(constant CompositeUniforms& u, float3 v) { return u.m[0] * v.x + u.m[1] * v.y + u.m[2] * v.z; }

    inline float3 sourceEncoded(constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc, float2 uv) {
        if (u.mode == 1) return ty.sample(linearSampler, uv).rgb;
        float y = ty.sample(linearSampler, uv).r * u.range.x + u.range.y;
        float2 c = tc.sample(linearSampler, uv).rg * u.range.z + u.range.w;
        return ycbcrToRGB(u, float3(y, c.x, c.y));
    }

    // One texel of an alpha source (mode 4, or mode 1 with alphaMode != 0) as premultiplied R'G'B'A. Premultiplied
    // Y'CbCr (offsets removed) maps to premultiplied R'G'B' through the same matrix (it is linear).
    inline float4 texelPremul(constant CompositeUniforms& u, texture2d<float> ty, uint2 p) {
        float4 t = ty.read(p);
        float4 c;
        if (u.mode == 4) {
            float3 ycc = float3(t.g * u.range.x + u.range.y, t.b * u.range.z + u.range.w, t.a * u.range.z + u.range.w);
            c = float4(ycbcrToRGB(u, ycc), t.r);
        } else {
            c = t;
        }
        // Premultiplied color cannot exceed its alpha; lossy coding (HEVC with alpha) overshoots at soft edges, which
        // un-premultiplying would turn into a bright halo.
        if (u.alphaMode == 2u) c.rgb = clamp(c.rgb, 0.0f, c.a);
        else c.rgb *= c.a;
        return c;
    }

    // Bilinear sample of premultiplied color (clamp to edge, like linearSampler). Filtering straight color would mix in the
    // color of invisible texels (dark or bright fringes on scaled or moved alpha video).
    inline float4 samplePremul(constant CompositeUniforms& u, texture2d<float> ty, float2 uv) {
        int2 mx = int2(ty.get_width(), ty.get_height()) - 1;
        float2 p = uv * float2(mx + 1) - 0.5f;
        float2 fl = floor(p), f = p - fl;
        int2 i0 = int2(fl);
        uint2 a = uint2(clamp(i0, int2(0), mx)), b = uint2(clamp(i0 + 1, int2(0), mx));
        float4 t00 = texelPremul(u, ty, a), t10 = texelPremul(u, ty, uint2(b.x, a.y));
        float4 t01 = texelPremul(u, ty, uint2(a.x, b.y)), t11 = texelPremul(u, ty, b);
        return mix(mix(t00, t10, f.x), mix(t01, t11, f.x), f.y);
    }

    inline bool alphaSource(constant CompositeUniforms& u) { return u.mode == 4 || (u.mode == 1 && u.alphaMode != 0u); }

    inline float3 inverseOETF709(float3 e) {
        e = max(e, 0.0f);
        float3 lo = e / 4.5f;
        float3 hi = pow((e + 0.09929682680944f) / 1.09929682680944f, 1.0f / 0.45f);
        return select(hi, lo, e < 0.081242858f);
    }

    // BT.709 OETF (exact inverse of inverseOETF709, extended above 1 by the same curve).
    inline float3 oetf709(float3 l) {
        l = max(l, 0.0f);
        float3 hi = 1.09929682680944f * pow(l, 0.45f) - 0.09929682680944f;
        return select(hi, l * 4.5f, l < 0.018053968510807f);
    }

    // Straight encoded color + alpha of one point of a mode 0 or mode 1 source (what convertToRGB writes at full size).
    inline float4 convertPoint(constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc, float2 uv) {
        if (u.mode == 1) {
            float4 c = ty.sample(linearSampler, uv);
            return float4(c.a > 0.0f ? c.rgb / c.a : float3(0.0f), c.a);
        }
        return float4(sourceEncoded(u, ty, tc, uv), 1.0f);
    }

    // What convertToRGB writes at `gid` of an `outSize` texture (also the first step of the fused grade kernels).
    inline float4 convertTexel(constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc, uint transfer,
                               uint2 gid, uint2 outSize) {
        float2 uv = (float2(gid) + 0.5f) / float2(outSize);
        if (outSize.x < ty.get_width()) {
            // Half resolution (playback perf, `colorWork`): the 2 x 2 source texels averaged in light, weighted by alpha, then
            // encoded again, so fine contrast does not darken the way an average of encoded values would. `transfer` is the
            // source curve (SourceColorSpace case order, `map3`); Rec.709 keeps the sign for sub-black and super-white.
            // Any other value: plain average of the encoded values.
            float2 d = 0.5f / float2(ty.get_width(), ty.get_height());
            float3 acc = 0.0f;
            float a = 0.0f;
            for (int k = 0; k < 4; k++) {
                float2 q = uv + float2(k & 1 ? d.x : -d.x, k & 2 ? d.y : -d.y);
                float4 e;
                if (alphaSource(u)) {
                    float4 c = samplePremul(u, ty, q);
                    e = float4(c.a > 0.0f ? c.rgb / c.a : float3(0.0f), c.a);
                } else {
                    e = convertPoint(u, ty, tc, q);
                }
                float3 l = transfer == 2u ? sign(e.rgb) * inverseOETF709(abs(e.rgb))
                         : transfer < 30u ? map3(e.rgb, int(transfer)) : e.rgb;
                acc += l * e.a;
                a += e.a;
            }
            float3 m = a > 0.0f ? acc / a : float3(0.0f);
            float3 enc = transfer == 2u ? sign(m) * oetf709(abs(m)) : transfer < 30u ? map3(m, int(transfer) + 10) : m;
            return float4(enc, a * 0.25f);
        }
        if (alphaSource(u)) {
            // Alpha video (or a straight RGB source): straight color + alpha for the color stage.
            float4 c = samplePremul(u, ty, uv);
            return float4(c.a > 0.0f ? c.rgb / c.a : float3(0.0f), c.a);
        }
        // RGB source with alpha (still image): keep alpha, color un-premultiplied for the color stage.
        return convertPoint(u, ty, tc, uv);
    }

    // Preview only (`Compositor.gradesAtDisplaySize`): converts to the size the layer is shown at, any ratio. Each output
    // texel averages n x n bilinear samples spread over its source footprint (n = ceil(ratio), 1...4 per axis), in light
    // through the source curve and weighted by alpha like the half-size path, so the grade that follows runs once per
    // shown pixel. `transfer` as in convertToRGB. Export never runs this kernel.
    inline float4 convertTexelScaled(constant CompositeUniforms& u, texture2d<float> ty, texture2d<float> tc, uint transfer,
                                     uint2 gid, uint2 outPixels) {
        float2 outSize = float2(outPixels);
        float2 texSize = float2(ty.get_width(), ty.get_height());
        float2 uv = (float2(gid) + 0.5f) / outSize;
        float2 ratio = texSize / outSize;
        int2 n = clamp(int2(ceil(ratio - 0.01f)), int2(1), int2(4));
        float2 step = ratio / float2(n) / texSize;     // uv distance between samples
        float3 acc = 0.0f;
        float a = 0.0f;
        for (int j = 0; j < n.y; j++) {
            for (int i = 0; i < n.x; i++) {
                float2 q = uv + (float2(i, j) + 0.5f - float2(n) * 0.5f) * step;
                float4 e;
                if (alphaSource(u)) {
                    float4 c = samplePremul(u, ty, q);
                    e = float4(c.a > 0.0f ? c.rgb / c.a : float3(0.0f), c.a);
                } else {
                    e = convertPoint(u, ty, tc, q);
                }
                float3 l = transfer == 2u ? sign(e.rgb) * inverseOETF709(abs(e.rgb))
                         : transfer < 30u ? map3(e.rgb, int(transfer)) : e.rgb;
                acc += l * e.a;
                a += e.a;
            }
        }
        float3 m = a > 0.0f ? acc / a : float3(0.0f);
        float3 enc = transfer == 2u ? sign(m) * oetf709(abs(m)) : transfer < 30u ? map3(m, int(transfer) + 10) : m;
        return float4(enc, a / float(n.x * n.y));
    }
    """
}
