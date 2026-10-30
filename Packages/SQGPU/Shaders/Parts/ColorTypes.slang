// Types of the color chain (mirror ColorPipelineGPU.Header / Sec). Include before the module's constant blocks:
// `ConstantBuffer<ColorChainU> cc : register(b0)`, `ConstantBuffer<CurveRows> curves : register(b1)`; then Bindings.slang,
// Parts/Transfer.slang and Parts/Color.slang.

// One block of the chain (layout mirrors ColorPipelineGPU.Sec: 128 bytes; m = the 3x3 matrix's columns, w unused).
struct Sec {
    uint4 head;   // kind, pre, flags, extra
    float4 a, b, c, d;
    float4 m0, m1, m2;
};

// ColorPipelineGPU.Header then up to ColorPipelineGPU.maxGroupSections blocks.
static const uint kMaxColorSections = 24;
struct ColorChainU {
    uint4 ints;   // section count, start domain (0 source-encoded, 1 source-linear, 2 display), end domain (1, 2, 3 = working-linear), source
    uint4 extra;  // x != 0: quarter-turned picture (vignette follows the upright picture); yz: dispatch origin
    Sec secs[kMaxColorSections];
};

// Curve tables: ColorPipelineGPU.maxCurves tables of kCurveCount rows.
static const uint kCurveCount = 64;
struct CurveRows { float4 rows[3 * kCurveCount]; };

