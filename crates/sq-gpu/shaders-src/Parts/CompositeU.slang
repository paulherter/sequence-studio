// CompositeU, the per-layer uniforms of the compositor kernels. Include before the module's constant buffers.

// Mirrors SQRender Compositor.Uniforms (368 bytes). The 3 x 3 matrix is three float4 columns and tilt a float4, which is
// how Metal lays out float3x3 and float3, and keeps the HLSL cbuffer packing identical.
struct CompositeU {
    float4 m0, m1, m2;    // Y'CbCr -> R'G'B' columns
    float4 solid;         // placeholder color (working-linear)
    float4 range;         // yScale, yBias, cScale, cBias
    float2 canvas;        // sequence size, px
    float2 size;          // layer size, px
    float2 position;      // offset from canvas center, px, y down
    float2 anchor;        // offset from layer center, px
    float2 scale;
    float rotCos, rotSin, opacity;
    uint mode;            // 0 YCbCr bi-planar, 1 RGB texture, 2 solid, 3 premultiplied RGBA group image, 4 packed AYCbCr
    uint linearize;       // 1 = apply inverse BT.709 OETF (no color stage)
    float cornerRadius;
    uint quarter;         // clockwise quarter turns of the source picture (modes 0 and 1)
    uint blend;           // blend mode id (BlendModes.shaderID)
    float2 maskSize;      // rectangle Crop / Rounded Corners work on, layer px; 0 = size
    float4 crop;          // left, top, right, bottom insets as fractions of maskSize
    float4 key0, key1;    // Ultra Key: hue (deg), half width (deg), soft edge (deg), spill (0...1)
    float4 matte0, matte1;
    float4 shape0, shape1;
    float4 cc0, cc1;
    uint keyCount;
    uint roundFirst;
    uint alphaMode;       // texture alpha (modes 1, 4): 0 legacy, 1 straight, 2 premultiplied
    uint maskCount;
    float cropFeather;
    float4 part;          // mode 3 partial buffer: its place (xy) and the whole picture's size (zw), texels
    float4 tilt;          // perspective tilt: x, y radians, camera distance px (z = 0: flat); w unused
};
