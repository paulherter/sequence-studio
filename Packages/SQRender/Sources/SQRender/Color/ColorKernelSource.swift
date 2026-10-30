/// Specialised color kernels: one generated MSL library per chain layout (which blocks, in which order, with which
/// structural flags). The values stay uniforms (`Sec`), so every clip with the same kind of grade shares the kernels.
///
/// The generated chain calls the very functions of the generic interpreter (`processPixel` in ColorShaderSource) with
/// the structure as literals: no section loop, no kind switch, no unused branches, fewer registers. Same operations in
/// the same order under `mathMode = .safe`, so the output is the generic path's, byte for byte (`GradeFusionTests`).
///
/// The fused kernels (`sqFused`, `sqFusedScaled`) also run the compositor's source conversion (`convertTexel`) first and
/// round its result the way the `rgba16Float` intermediate store did (`storeHalf`), which saves a full-size write and
/// read per graded layer.
enum ColorKernelSource {
    /// The structure of one block that a specialised kernel bakes in.
    struct Block: Hashable, Sendable {
        var kind: UInt32
        var pre: Bool
        /// s.head.z for the kinds that branch on it (conversion, basic, creative, look, wheels), else 0.
        var flags: UInt32
        /// Basic: Lumetri tone model (s.head.w == 1).
        var lumetri: Bool
    }

    /// The structure of one pass (`ColorPipelineGPU.Pass`).
    struct PassLayout: Hashable, Sendable {
        var start: UInt32, end: UInt32, source: UInt32
        var blocks: [Block]
    }

    static func layout(_ p: ColorPipelineGPU.Pass) -> PassLayout {
        PassLayout(start: p.header.ints.y, end: p.header.ints.z, source: p.header.ints.w, blocks: p.sections.map { s in
            let k = s.head.x
            let branches = k == ColorPipelineGPU.kindConversion || k == ColorPipelineGPU.kindBasic
                || k == ColorPipelineGPU.kindCreative || k == ColorPipelineGPU.kindLook || k == ColorPipelineGPU.kindWheels
                || k == ColorPipelineGPU.kindPrimaries || k == ColorPipelineGPU.kindStepEnd
                || k == ColorPipelineGPU.kindBranchEnd || k == ColorPipelineGPU.kindGroupMerge || k == ColorPipelineGPU.kindKeyTerm
            return Block(kind: k, pre: s.head.y != 0, flags: branches ? s.head.z : 0,
                         lumetri: k == ColorPipelineGPU.kindBasic && s.head.w == 1)
        })
    }

    private static func call(_ b: Block, _ i: Int, source: UInt32) -> String {
        let s = "secs[\(i)]", pre = b.pre ? "true" : "false"
        switch b.kind {
        case ColorPipelineGPU.kindConversion: return "conversionStage(c, \(s), \(source), \(b.flags)u, lut3, lut1)"
        case ColorPipelineGPU.kindBasic: return "basicStageF(c, \(s), \(pre), \(b.flags)u, \(b.lumetri))"
        case ColorPipelineGPU.kindCreative: return "creativeStageF(c, \(s), \(pre), \(b.flags & 1 != 0))"
        case ColorPipelineGPU.kindLook: return "lookStage(c, \(s), \(pre), \(b.flags)u, lut3, lut1)"
        case ColorPipelineGPU.kindCurves: return "curvesStage(c, \(s), \(pre), curves)"
        case ColorPipelineGPU.kindWheels: return "wheelsStageF(c, \(s), \(pre), \(b.flags & 1 != 0))"
        case ColorPipelineGPU.kindVignette: return "vignetteStage(c, \(s), \(pre), uv, aspect)"
        case ColorPipelineGPU.kindHueCurves: return "hueCurvesStage(c, \(s), \(pre), curves)"
        case ColorPipelineGPU.kindHSLSecondary: return "hslSecondaryStage(c, \(s), \(pre))"
        case ColorPipelineGPU.kindZoneBoard: return "zoneBoardStage(c, \(s), \(pre))"
        case ColorPipelineGPU.kindPrimaries: return "primariesStage(c, \(s), \(pre), \(b.flags)u)"
        case ColorPipelineGPU.kindStepEnd:
            return "stepEndStage(c, n0, \(s), \(pre), \(b.flags)u, uv, aspect, \(b.flags & 16 != 0 ? "km" : "1.0f"))"
        default: return "c"
        }
    }

    /// One generated line: a Step begin keeps the signal in `n0`, every other block maps `c`.
    private static func line(_ b: Block, _ i: Int, source: UInt32) -> String {
        switch b.kind {
        case ColorPipelineGPU.kindStepBegin: return "    n0 = c;\n"
        case ColorPipelineGPU.kindGroupBegin: return "    n0 = c; acc = float3(0.0f);\n"
        case ColorPipelineGPU.kindBranchEnd:
            let keyed = b.flags & 16 != 0
            return "    branchEndStage(c, n0, acc, secs[\(i)], \(b.pre ? "true" : "false"), \(b.flags)u, uv, aspect, \(keyed ? "km" : "1.0f")); \(keyed ? "km = 1.0f; " : "")c = n0;\n"
        case ColorPipelineGPU.kindKeyTerm:
            return "    km = keyTermStage(n0, secs[\(i)], \(b.pre ? "true" : "false"), \(b.flags)u, uv, aspect, km);\n"
        case ColorPipelineGPU.kindKeyApply: return "    acc = n0 + (acc - n0) * km; km = 1.0f;\n"
        case ColorPipelineGPU.kindStepEnd where b.flags & 16 != 0:
            return "    c = \(call(b, i, source: source)); km = 1.0f;\n"
        case ColorPipelineGPU.kindGroupMerge: return "    acc = \(b.flags & 1 != 0 ? "n0" : "acc * secs[\(i)].a.x");\n"
        case ColorPipelineGPU.kindGroupEnd: return "    c = acc;\n"
        default: return "    c = \(call(b, i, source: source));\n"
        }
    }

    /// `float3 n0` for chains with limited Steps or columns, `acc` for columns.
    private static func stepRegister<S: Sequence>(_ blocks: S) -> String where S.Element == Block {
        let group = blocks.contains { $0.kind == ColorPipelineGPU.kindGroupBegin }
        let step = blocks.contains { $0.kind == ColorPipelineGPU.kindStepBegin }
        let keys = blocks.contains { $0.kind == ColorPipelineGPU.kindKeyTerm }
        return (step || group ? "    float3 n0 = c;\n" : "") + (group ? "    float3 acc = float3(0.0f);\n" : "")
            + (keys ? "    float km = 1.0f;\n" : "")
    }

    /// `processPixel` unrolled for one pass.
    private static func chain(_ p: PassLayout, index n: Int) -> String {
        var out = """
        float3 sqChain\(n)(float3 px, constant Sec *secs, constant float4 *curves,
                           texture3d<float, access::read> lut3, texture2d<float, access::read> lut1, float2 uv, float aspect) {
            float3 c = \(p.start == 0 ? "map3(px, \(p.source))" : "px");

        """
        out += stepRegister(p.blocks)
        for (i, b) in p.blocks.enumerated() { out += line(b, i, source: p.source) }
        out += "    return \(p.end == 3 ? "map3(c, 2)" : "c");\n}\n"
        return out
    }

    private static let chainArgs = """
        texture3d<float, access::read> lut3 [[texture(2)]], texture2d<float, access::read> lut1 [[texture(3)]],
        constant ColorHeader &h [[buffer(0)]], constant Sec *secs [[buffer(1)]], constant float4 *curves [[buffer(2)]],
        uint2 tid [[thread_position_in_grid]]
    """

    /// Same bodies as `colorChain` / `colorChainInPlace`, the chain call specialised.
    private static func passKernels(_ n: Int) -> String {
        """
        kernel void sqPass\(n)(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
        \(chainArgs)) {
            uint2 gid = tid + h.extra.yz;
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float4 px = src.read(gid);
            float2 uv = (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height());
            float aspect = float(dst.get_width()) / float(dst.get_height());
            if (h.extra.x != 0u) { uv = uv.yx; aspect = 1.0f / aspect; }
            dst.write(float4(sqChain\(n)(px.rgb, secs, curves, lut3, lut1, uv, aspect), px.a), gid);
        }

        kernel void sqPass\(n)InPlace(texture2d<float, access::read_write> img [[texture(0)]],
        \(chainArgs)) {
            uint2 gid = tid + h.extra.yz;
            if (gid.x >= img.get_width() || gid.y >= img.get_height()) { return; }
            float4 px = img.read(gid);
            float2 uv = (float2(gid) + 0.5f) / float2(img.get_width(), img.get_height());
            float aspect = float(img.get_width()) / float(img.get_height());
            if (h.extra.x != 0u) { uv = uv.yx; aspect = 1.0f / aspect; }
            img.write(float4(sqChain\(n)(px.rgb, secs, curves, lut3, lut1, uv, aspect), px.a), gid);
        }

        """
    }

    /// Source conversion + first pass in one dispatch. Bindings: the compositor's (textures 0-2, buffers 0-2) and the
    /// chain's after them (LUT textures 3-4, header/sections/curves buffers 3-5). Dispatch origin: `origin` (= h.extra.yz).
    private static func fusedKernel(_ name: String, convert: String) -> String {
        """
        kernel void \(name)(texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                            texture2d<float, access::write> out [[texture(2)]],
                            texture3d<float, access::read> lut3 [[texture(3)]], texture2d<float, access::read> lut1 [[texture(4)]],
                            constant CompositeUniforms& u [[buffer(0)]], constant uint2& origin [[buffer(1)]],
                            constant uint& transfer [[buffer(2)]],
                            constant ColorHeader &h [[buffer(3)]], constant Sec *secs [[buffer(4)]], constant float4 *curves [[buffer(5)]],
                            uint2 tid [[thread_position_in_grid]]) {
            uint2 gid = tid + origin;
            uint2 size = uint2(out.get_width(), out.get_height());
            if (gid.x >= size.x || gid.y >= size.y) { return; }
            float4 px = storeHalf(\(convert)(u, ty, tc, transfer, gid, size));
            float2 uv = (float2(gid) + 0.5f) / float2(size);
            float aspect = float(size.x) / float(size.y);
            if (h.extra.x != 0u) { uv = uv.yx; aspect = 1.0f / aspect; }
            out.write(float4(sqChain0(px.rgb, secs, curves, lut3, lut1, uv, aspect), px.a), gid);
        }

        """
    }

    /// Index of the conversion block in a pass that starts at the source (pass 0), nil when the pass has none: the
    /// point up to which `sqFusedScaledTone` works per source sample.
    static func conversionIndex(_ p: PassLayout) -> Int? {
        p.start == 0 ? p.blocks.firstIndex { $0.kind == ColorPipelineGPU.kindConversion } : nil
    }

    /// Pass 0 cut at its conversion: `sqHead0` (decode, blocks up to and including the conversion: source sample ->
    /// display signal) and `sqTail0` (the blocks after it and the pass's end mapping). Same stage calls as `sqChain0`.
    private static func splitChain(_ p: PassLayout, at k: Int) -> String {
        let args = "constant Sec *secs, constant float4 *curves, texture3d<float, access::read> lut3, "
            + "texture2d<float, access::read> lut1, float2 uv, float aspect"
        var out = "float3 sqHead0(float3 px, \(args)) {\n    float3 c = map3(px, \(p.source));\n"
        out += stepRegister(p.blocks.prefix(k + 1))
        for (i, b) in p.blocks.enumerated() where i <= k { out += line(b, i, source: p.source) }
        out += "    return c;\n}\n\nfloat3 sqTail0(float3 c, \(args)) {\n"
        out += stepRegister(p.blocks.dropFirst(k + 1))
        for (i, b) in p.blocks.enumerated() where i > k { out += line(b, i, source: p.source) }
        out += "    return \(p.end == 3 ? "map3(c, 2)" : "c");\n}\n"
        return out
    }

    /// Preview only (`Compositor.gradesAtDisplaySize`), for sources that must not be averaged before their tone map
    /// (log, PQ: `Compositor.averagesBeforeGrading` false). Like `sqFusedScaled` it writes one texel per shown pixel
    /// from n x n samples of the source, but every sample goes through the chain up to its conversion first (`sqHead0`:
    /// the tone map runs per source sample, as in export); the display signals are averaged in light, weighted by alpha,
    /// and only the rest of the pass (`sqTail0`) runs once per shown pixel. Same bindings as `sqFused`.
    private static let toneFirstKernel = """
        kernel void sqFusedScaledTone(texture2d<float> ty [[texture(0)]], texture2d<float> tc [[texture(1)]],
                            texture2d<float, access::write> out [[texture(2)]],
                            texture3d<float, access::read> lut3 [[texture(3)]], texture2d<float, access::read> lut1 [[texture(4)]],
                            constant CompositeUniforms& u [[buffer(0)]], constant uint2& origin [[buffer(1)]],
                            constant uint& transfer [[buffer(2)]],
                            constant ColorHeader &h [[buffer(3)]], constant Sec *secs [[buffer(4)]], constant float4 *curves [[buffer(5)]],
                            uint2 tid [[thread_position_in_grid]]) {
            uint2 gid = tid + origin;
            uint2 size = uint2(out.get_width(), out.get_height());
            if (gid.x >= size.x || gid.y >= size.y) { return; }
            float2 outSize = float2(size);
            float2 texSize = float2(ty.get_width(), ty.get_height());
            float2 at = (float2(gid) + 0.5f) / outSize;
            float2 uv = at;
            float aspect = outSize.x / outSize.y;
            if (h.extra.x != 0u) { uv = uv.yx; aspect = 1.0f / aspect; }
            float2 ratio = texSize / outSize;
            int2 n = clamp(int2(ceil(ratio - 0.01f)), int2(1), int2(4));
            float2 step = ratio / float2(n) / texSize;     // uv distance between samples
            float3 acc = 0.0f;
            float a = 0.0f;
            for (int j = 0; j < n.y; j++) {
                for (int i = 0; i < n.x; i++) {
                    float2 q = at + (float2(i, j) + 0.5f - float2(n) * 0.5f) * step;
                    float4 e;
                    if (alphaSource(u)) {
                        float4 c = samplePremul(u, ty, q);
                        e = float4(c.a > 0.0f ? c.rgb / c.a : float3(0.0f), c.a);
                    } else {
                        e = convertPoint(u, ty, tc, q);
                    }
                    float3 d = sqHead0(e.rgb, secs, curves, lut3, lut1, uv, aspect);
                    acc += sign(d) * inverseOETF709(abs(d)) * e.a;
                    a += e.a;
                }
            }
            float3 m = a > 0.0f ? acc / a : float3(0.0f);
            float4 px = storeHalf(float4(sign(m) * oetf709(abs(m)), a / float(n.x * n.y)));
            out.write(float4(sqTail0(px.rgb, secs, curves, lut3, lut1, uv, aspect), px.a), gid);
        }

        """

    /// The whole library for one chain layout: kernels `sqPass<i>`, `sqPass<i>InPlace`, and `sqFused`, `sqFusedScaled`
    /// for pass 0, plus `sqFusedScaledTone` when pass 0 holds the conversion.
    static func library(for layouts: [PassLayout]) -> String {
        var s = ColorShaderSource.mslHead + "\n" + ColorShaderSource.transferMSL + "\n" + ColorShaderSource.storeHalfMSL + "\n"
            + CompositorShaderSource.convertMSL + "\n" + ColorShaderSource.mslTail + "\n"
        for (i, p) in layouts.enumerated() { s += chain(p, index: i) + "\n" + passKernels(i) }
        if !layouts.isEmpty {
            s += fusedKernel("sqFused", convert: "convertTexel") + fusedKernel("sqFusedScaled", convert: "convertTexelScaled")
            if let k = conversionIndex(layouts[0]) { s += splitChain(layouts[0], at: k) + "\n" + toneFirstKernel }
        }
        return s
    }
}
